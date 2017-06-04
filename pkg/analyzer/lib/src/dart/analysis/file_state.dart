// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/dart/analysis/defined_names.dart';
import 'package:analyzer/src/dart/analysis/referenced_names.dart';
import 'package:analyzer/src/dart/analysis/top_level_declaration.dart';
import 'package:analyzer/src/dart/scanner/reader.dart';
import 'package:analyzer/src/dart/scanner/scanner.dart';
import 'package:analyzer/src/fasta/ast_builder.dart' as fasta;
import 'package:analyzer/src/fasta/element_store.dart' as fasta;
import 'package:analyzer/src/fasta/mock_element.dart' as fasta;
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:analyzer/src/source/source_resource.dart';
import 'package:analyzer/src/summary/format.dart';
import 'package:analyzer/src/summary/idl.dart';
import 'package:analyzer/src/summary/name_filter.dart';
import 'package:analyzer/src/summary/package_bundle_reader.dart';
import 'package:analyzer/src/summary/summarize_ast.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:front_end/src/base/api_signature.dart';
import 'package:front_end/src/base/performace_logger.dart';
import 'package:front_end/src/fasta/builder/builder.dart' as fasta;
import 'package:front_end/src/fasta/parser/parser.dart' as fasta;
import 'package:front_end/src/fasta/scanner.dart' as fasta;
import 'package:front_end/src/incremental/byte_store.dart';
import 'package:meta/meta.dart';

/**
 * [FileContentOverlay] is used to temporary override content of files.
 */
class FileContentOverlay {
  final _map = <String, String>{};

  /**
   * Return the content of the file with the given [path], or `null` the
   * overlay does not override the content of the file.
   *
   * The [path] must be absolute and normalized.
   */
  String operator [](String path) => _map[path];

  /**
   * Return the new [content] of the file with the given [path].
   *
   * The [path] must be absolute and normalized.
   */
  void operator []=(String path, String content) {
    if (content == null) {
      _map.remove(path);
    } else {
      _map[path] = content;
    }
  }

  /**
   * Return the paths currently being overridden.
   */
  Iterable<String> get paths => _map.keys;
}

/**
 * Information about a file being analyzed, explicitly or implicitly.
 *
 * It provides a consistent view on its properties.
 *
 * The properties are not guaranteed to represent the most recent state
 * of the file system. To update the file to the most recent state, [refresh]
 * should be called.
 */
class FileState {
  static const bool USE_FASTA_PARSER = false;

  final FileSystemState _fsState;

  /**
   * The absolute path of the file.
   */
  final String path;

  /**
   * The absolute URI of the file.
   */
  final Uri uri;

  /**
   * The [Source] of the file with the [uri].
   */
  final Source source;

  /**
   * Return `true` if this file is a stub created for a file in the provided
   * external summary store. The values of most properties are not the same
   * as they would be if the file were actually read from the file system.
   * The value of the property [uri] is correct.
   */
  final bool isInExternalSummaries;

  bool _exists;
  List<int> _contentBytes;
  String _content;
  String _contentHash;
  LineInfo _lineInfo;
  Set<String> _definedTopLevelNames;
  Set<String> _definedClassMemberNames;
  Set<String> _referencedNames;
  UnlinkedUnit _unlinked;
  List<int> _apiSignature;

  List<FileState> _importedFiles;
  List<FileState> _exportedFiles;
  List<FileState> _partedFiles;
  List<NameFilter> _exportFilters;

  Set<FileState> _directReferencedFiles = new Set<FileState>();
  Set<FileState> _transitiveFiles;
  String _transitiveSignature;

  Map<String, TopLevelDeclaration> _topLevelDeclarations;
  Map<String, TopLevelDeclaration> _exportedTopLevelDeclarations;

  /**
   * The flag that shows whether the file has an error or warning that
   * might be fixed by a change to another file.
   */
  bool hasErrorOrWarning = false;

  FileState._(this._fsState, this.path, this.uri, this.source)
      : isInExternalSummaries = false;

  FileState._external(this._fsState, this.uri)
      : isInExternalSummaries = true,
        path = null,
        source = null {
    _apiSignature = new Uint8List(16);
  }

  /**
   * The unlinked API signature of the file.
   */
  List<int> get apiSignature => _apiSignature;

  /**
   * The content of the file.
   */
  String get content => _content;

  /**
   * The MD5 hash of the [content].
   */
  String get contentHash => _contentHash;

  /**
   * The class member names defined by the file.
   */
  Set<String> get definedClassMemberNames => _definedClassMemberNames;

  /**
   * The top-level names defined by the file.
   */
  Set<String> get definedTopLevelNames => _definedTopLevelNames;

  /**
   * Return the set of all directly referenced files - imported, exported or
   * parted.
   */
  Set<FileState> get directReferencedFiles => _directReferencedFiles;

  /**
   * Return `true` if the file exists.
   */
  bool get exists => _exists;

  /**
   * The list of files this file exports.
   */
  List<FileState> get exportedFiles => _exportedFiles;

  /**
   * Return [TopLevelDeclaration]s exported from the this library file. The
   * keys to the map are names of declarations.
   */
  Map<String, TopLevelDeclaration> get exportedTopLevelDeclarations {
    if (_exportedTopLevelDeclarations == null) {
      _exportedTopLevelDeclarations = <String, TopLevelDeclaration>{};

      Set<FileState> seenLibraries = new Set<FileState>();

      /**
       * Compute [TopLevelDeclaration]s exported from the [library].
       */
      Map<String, TopLevelDeclaration> computeExported(FileState library) {
        var declarations = <String, TopLevelDeclaration>{};
        if (seenLibraries.add(library)) {
          // Append the exported declarations.
          for (int i = 0; i < library._exportedFiles.length; i++) {
            Map<String, TopLevelDeclaration> exported =
                computeExported(library._exportedFiles[i]);
            for (TopLevelDeclaration t in exported.values) {
              if (library._exportFilters[i].accepts(t.name)) {
                declarations[t.name] = t;
              }
            }
          }

          // Append the library declarations.
          declarations.addAll(library.topLevelDeclarations);
          for (FileState part in library.partedFiles) {
            declarations.addAll(part.topLevelDeclarations);
          }

          // We're done with this library.
          seenLibraries.remove(library);
        }

        return declarations;
      }

      _exportedTopLevelDeclarations = computeExported(this);
    }
    return _exportedTopLevelDeclarations;
  }

  @override
  int get hashCode => uri.hashCode;

  /**
   * The list of files this file imports.
   */
  List<FileState> get importedFiles => _importedFiles;

  /**
   * Return `true` if the file does not have a `library` directive, and has a
   * `part of` directive, so is probably a part.
   */
  bool get isPart => _unlinked.libraryNameOffset == 0 && _unlinked.isPartOf;

  /**
   * If the file [isPart], return a currently know library the file is a part
   * of. Return `null` if a library is not known, for example because we have
   * not processed a library file yet.
   */
  FileState get library {
    List<FileState> libraries = _fsState._partToLibraries[this];
    if (libraries == null || libraries.isEmpty) {
      return null;
    } else {
      return libraries.first;
    }
  }

  /**
   * Return information about line in the file.
   */
  LineInfo get lineInfo => _lineInfo;

  /**
   * The list of files this library file references as parts.
   */
  List<FileState> get partedFiles => _partedFiles;

  /**
   * The external names referenced by the file.
   */
  Set<String> get referencedNames => _referencedNames;

  /**
   * Return public top-level declarations declared in the file. The keys to the
   * map are names of declarations.
   */
  Map<String, TopLevelDeclaration> get topLevelDeclarations {
    if (_topLevelDeclarations == null) {
      _topLevelDeclarations = <String, TopLevelDeclaration>{};

      void addDeclaration(TopLevelDeclarationKind kind, String name) {
        if (!name.startsWith('_')) {
          _topLevelDeclarations[name] = new TopLevelDeclaration(kind, name);
        }
      }

      // Add types.
      for (UnlinkedClass type in unlinked.classes) {
        addDeclaration(TopLevelDeclarationKind.type, type.name);
      }
      for (UnlinkedEnum type in unlinked.enums) {
        addDeclaration(TopLevelDeclarationKind.type, type.name);
      }
      for (UnlinkedTypedef type in unlinked.typedefs) {
        addDeclaration(TopLevelDeclarationKind.type, type.name);
      }
      // Add functions and variables.
      Set<String> addedVariableNames = new Set<String>();
      for (UnlinkedExecutable executable in unlinked.executables) {
        String name = executable.name;
        if (executable.kind == UnlinkedExecutableKind.functionOrMethod) {
          addDeclaration(TopLevelDeclarationKind.function, name);
        } else if (executable.kind == UnlinkedExecutableKind.getter ||
            executable.kind == UnlinkedExecutableKind.setter) {
          if (executable.kind == UnlinkedExecutableKind.setter) {
            name = name.substring(0, name.length - 1);
          }
          if (addedVariableNames.add(name)) {
            addDeclaration(TopLevelDeclarationKind.variable, name);
          }
        }
      }
      for (UnlinkedVariable variable in unlinked.variables) {
        String name = variable.name;
        if (addedVariableNames.add(name)) {
          addDeclaration(TopLevelDeclarationKind.variable, name);
        }
      }
    }
    return _topLevelDeclarations;
  }

  /**
   * Return the set of transitive files - the file itself and all of the
   * directly or indirectly referenced files.
   */
  Set<FileState> get transitiveFiles {
    if (_transitiveFiles == null) {
      _transitiveFiles = new Set<FileState>();

      void appendReferenced(FileState file) {
        if (_transitiveFiles.add(file)) {
          file._directReferencedFiles.forEach(appendReferenced);
        }
      }

      appendReferenced(this);
    }
    return _transitiveFiles;
  }

  /**
   * Return the signature of the file, based on the [transitiveFiles].
   */
  String get transitiveSignature {
    if (_transitiveSignature == null) {
      ApiSignature signature = new ApiSignature();
      signature.addUint32List(_fsState._salt);
      signature.addInt(transitiveFiles.length);
      transitiveFiles
          .map((file) => file.apiSignature)
          .forEach(signature.addBytes);
      signature.addString(uri.toString());
      _transitiveSignature = signature.toHex();
    }
    return _transitiveSignature;
  }

  /**
   * The [UnlinkedUnit] of the file.
   */
  UnlinkedUnit get unlinked => _unlinked;

  /**
   * Return the [uri] string.
   */
  String get uriStr => uri.toString();

  @override
  bool operator ==(Object other) {
    return other is FileState && other.uri == uri;
  }

  /**
   * Return a new parsed unresolved [CompilationUnit].
   */
  CompilationUnit parse(AnalysisErrorListener errorListener) {
    return PerformanceStatistics.parse.makeCurrentWhile(() {
      return _parse(errorListener);
    });
  }

  CompilationUnit _parse(AnalysisErrorListener errorListener) {
    AnalysisOptions analysisOptions = _fsState._analysisOptions;

    if (USE_FASTA_PARSER) {
      try {
        fasta.ScannerResult scanResult =
            PerformanceStatistics.scan.makeCurrentWhile(() {
          return fasta.scan(
            _contentBytes,
            includeComments: true,
            scanGenericMethodComments: analysisOptions.strongMode,
          );
        });

        var astBuilder = new fasta.AstBuilder(
            new ErrorReporter(errorListener, source),
            null,
            null,
            new _FastaElementStoreProxy(),
            new fasta.Scope.top(isModifiable: true),
            uri);
        astBuilder.parseGenericMethodComments = analysisOptions.strongMode;

        var parser = new fasta.Parser(astBuilder);
        astBuilder.parser = parser;
        parser.parseUnit(scanResult.tokens);
        var unit = astBuilder.pop() as CompilationUnit;

        LineInfo lineInfo = new LineInfo(scanResult.lineStarts);
        unit.lineInfo = lineInfo;
        return unit;
      } catch (e, st) {
        print(e);
        print(st);
        rethrow;
      }
    } else {
      CharSequenceReader reader = new CharSequenceReader(content);
      Scanner scanner = new Scanner(source, reader, errorListener);
      scanner.scanGenericMethodComments = analysisOptions.strongMode;
      Token token = PerformanceStatistics.scan.makeCurrentWhile(() {
        return scanner.tokenize();
      });
      LineInfo lineInfo = new LineInfo(scanner.lineStarts);

      Parser parser = new Parser(source, errorListener);
      parser.enableAssertInitializer = analysisOptions.enableAssertInitializer;
      parser.parseGenericMethodComments = analysisOptions.strongMode;
      CompilationUnit unit = parser.parseCompilationUnit(token);
      unit.lineInfo = lineInfo;
      return unit;
    }
  }

  /**
   * Read the file content and ensure that all of the file properties are
   * consistent with the read content, including API signature.
   *
   * Return `true` if the API signature changed since the last refresh.
   */
  bool refresh() {
    // Read the content.
    try {
      _content = _fsState._contentOverlay[path];
      _content ??= _fsState._resourceProvider.getFile(path).readAsStringSync();
      _exists = true;
    } catch (_) {
      _content = '';
      _exists = false;
    }

    if (USE_FASTA_PARSER) {
      var bytes = UTF8.encode(_content);
      _contentBytes = new Uint8List(bytes.length + 1);
      _contentBytes.setRange(0, bytes.length, bytes);
      _contentBytes[_contentBytes.length - 1] = 0;
    }

    // Compute the content hash.
    List<int> contentBytes = UTF8.encode(_content);
    {
      List<int> hashBytes = md5.convert(contentBytes).bytes;
      _contentHash = hex.encode(hashBytes);
    }

    // Prepare the unlinked bundle key.
    String unlinkedKey;
    {
      ApiSignature signature = new ApiSignature();
      signature.addUint32List(_fsState._salt);
      signature.addInt(contentBytes.length);
      signature.addString(_contentHash);
      unlinkedKey = '${signature.toHex()}.unlinked';
    }

    // Prepare bytes of the unlinked bundle - existing or new.
    List<int> bytes;
    {
      bytes = _fsState._byteStore.get(unlinkedKey);
      if (bytes == null) {
        CompilationUnit unit = parse(AnalysisErrorListener.NULL_LISTENER);
        _fsState._logger.run('Create unlinked for $path', () {
          UnlinkedUnitBuilder unlinkedUnit = serializeAstUnlinked(unit);
          List<String> referencedNames = computeReferencedNames(unit).toList();
          DefinedNames definedNames = computeDefinedNames(unit);
          bytes = new AnalysisDriverUnlinkedUnitBuilder(
                  unit: unlinkedUnit,
                  definedTopLevelNames: definedNames.topLevelNames.toList(),
                  definedClassMemberNames:
                      definedNames.classMemberNames.toList(),
                  referencedNames: referencedNames)
              .toBuffer();
          _fsState._byteStore.put(unlinkedKey, bytes);
        });
      }
    }

    // Read the unlinked bundle.
    var driverUnlinkedUnit = new AnalysisDriverUnlinkedUnit.fromBuffer(bytes);
    _definedTopLevelNames = driverUnlinkedUnit.definedTopLevelNames.toSet();
    _definedClassMemberNames =
        driverUnlinkedUnit.definedClassMemberNames.toSet();
    _referencedNames = driverUnlinkedUnit.referencedNames.toSet();
    _unlinked = driverUnlinkedUnit.unit;
    _lineInfo = new LineInfo(_unlinked.lineStarts);
    _topLevelDeclarations = null;

    // Prepare API signature.
    List<int> newApiSignature = new Uint8List.fromList(_unlinked.apiSignature);
    bool apiSignatureChanged = _apiSignature != null &&
        !_equalByteLists(_apiSignature, newApiSignature);
    _apiSignature = newApiSignature;

    // The API signature changed.
    //   Flush transitive signatures of affected files.
    //   Flush exported top-level declarations of all files.
    if (apiSignatureChanged) {
      for (FileState file in _fsState._uriToFile.values) {
        if (file._transitiveFiles != null &&
            file._transitiveFiles.contains(this)) {
          file._transitiveSignature = null;
        }
        file._exportedTopLevelDeclarations = null;
      }
    }

    // This file is potentially not a library for its previous parts anymore.
    if (_partedFiles != null) {
      for (FileState part in _partedFiles) {
        _fsState._partToLibraries[part]?.remove(this);
      }
    }

    // Build the graph.
    _importedFiles = <FileState>[];
    _exportedFiles = <FileState>[];
    _partedFiles = <FileState>[];
    _exportFilters = <NameFilter>[];
    for (UnlinkedImport import in _unlinked.imports) {
      String uri = import.isImplicit ? 'dart:core' : import.uri;
      FileState file = _fileForRelativeUri(uri);
      _importedFiles.add(file);
    }
    for (UnlinkedExportPublic export in _unlinked.publicNamespace.exports) {
      String uri = export.uri;
      FileState file = _fileForRelativeUri(uri);
      _exportedFiles.add(file);
      _exportFilters
          .add(new NameFilter.forUnlinkedCombinators(export.combinators));
    }
    for (String uri in _unlinked.publicNamespace.parts) {
      FileState file = _fileForRelativeUri(uri);
      _partedFiles.add(file);
      // TODO(scheglov) Sort for stable results?
      _fsState._partToLibraries
          .putIfAbsent(file, () => <FileState>[])
          .add(this);
    }

    // Compute referenced files.
    Set<FileState> oldDirectReferencedFiles = _directReferencedFiles;
    _directReferencedFiles = new Set<FileState>()
      ..addAll(_importedFiles)
      ..addAll(_exportedFiles)
      ..addAll(_partedFiles);

    // If the set of directly referenced files of this file is changed,
    // then the transitive sets of files that include this file are also
    // changed. Reset these transitive sets.
    if (_directReferencedFiles.length != oldDirectReferencedFiles.length ||
        !_directReferencedFiles.containsAll(oldDirectReferencedFiles)) {
      for (FileState file in _fsState._uriToFile.values) {
        if (file._transitiveFiles != null &&
            file._transitiveFiles.contains(this)) {
          file._transitiveFiles = null;
        }
      }
    }

    // Return whether the API signature changed.
    return apiSignatureChanged;
  }

  @override
  String toString() => path;

  /**
   * Return the [FileState] for the given [relativeUri], maybe "unresolved"
   * file if the URI cannot be parsed, cannot correspond any file, etc.
   */
  FileState _fileForRelativeUri(String relativeUri) {
    if (relativeUri.isEmpty) {
      return _fsState.unresolvedFile;
    }

    Uri absoluteUri;
    try {
      absoluteUri = resolveRelativeUri(uri, Uri.parse(relativeUri));
    } on FormatException {
      return _fsState.unresolvedFile;
    }

    return _fsState.getFileForUri(absoluteUri);
  }

  /**
   * Return `true` if the given byte lists are equal.
   */
  static bool _equalByteLists(List<int> a, List<int> b) {
    if (a == null) {
      return b == null;
    } else if (b == null) {
      return false;
    }
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

/**
 * Information about known file system state.
 */
class FileSystemState {
  final PerformanceLog _logger;
  final ResourceProvider _resourceProvider;
  final ByteStore _byteStore;
  final FileContentOverlay _contentOverlay;
  final SourceFactory _sourceFactory;
  final AnalysisOptions _analysisOptions;
  final Uint32List _salt;

  /**
   * The optional store with externally provided unlinked and corresponding
   * linked summaries. These summaries are always added to the store for any
   * file analysis.
   *
   * While walking the file graph, when we reach a file that exists in the
   * external store, we add a stub [FileState], but don't attempt to read its
   * content, or its unlinked unit, or imported libraries, etc.
   */
  final SummaryDataStore externalSummaries;

  /**
   * Mapping from a URI to the corresponding [FileState].
   */
  final Map<Uri, FileState> _uriToFile = {};

  /**
   * All known file paths.
   */
  final Set<String> knownFilePaths = new Set<String>();

  /**
   * The paths of files that were added to the set of known files since the
   * last [knownFilesSetChanges] notification.
   */
  final Set<String> _addedKnownFiles = new Set<String>();

  /**
   * If not `null`, this delay will be awaited instead of the default one.
   */
  Duration _knownFilesSetChangesDelay;

  /**
   * The instance of timer that is scheduled to send a new update to the
   * [knownFilesSetChanges] stream, or `null` if there are no changes to the
   * set of known files to notify the stream about.
   */
  Timer _knownFilesSetChangesTimer;

  /**
   * The controller for the [knownFilesSetChanges] stream.
   */
  final StreamController<KnownFilesSetChange> _knownFilesSetChangesController =
      new StreamController<KnownFilesSetChange>();

  /**
   * Mapping from a path to the flag whether there is a URI for the path.
   */
  final Map<String, bool> _hasUriForPath = {};

  /**
   * Mapping from a path to the corresponding [FileState]s, canonical or not.
   */
  final Map<String, List<FileState>> _pathToFiles = {};

  /**
   * Mapping from a path to the corresponding canonical [FileState].
   */
  final Map<String, FileState> _pathToCanonicalFile = {};

  /**
   * Mapping from a part to the libraries it is a part of.
   */
  final Map<FileState, List<FileState>> _partToLibraries = {};

  /**
   * The [FileState] instance that correspond to an unresolved URI.
   */
  FileState _unresolvedFile;

  FileSystemStateTestView _testView;

  FileSystemState(
      this._logger,
      this._byteStore,
      this._contentOverlay,
      this._resourceProvider,
      this._sourceFactory,
      this._analysisOptions,
      this._salt,
      {this.externalSummaries}) {
    _testView = new FileSystemStateTestView(this);
  }

  /**
   * Return the known files.
   */
  List<FileState> get knownFiles =>
      _pathToFiles.values.map((files) => files.first).toList();

  /**
   * Return the [Stream] that is periodically notified about changes to the
   * known files set.
   */
  Stream<KnownFilesSetChange> get knownFilesSetChanges =>
      _knownFilesSetChangesController.stream;

  @visibleForTesting
  FileSystemStateTestView get test => _testView;

  /**
   * Return the [FileState] instance that correspond to an unresolved URI.
   */
  FileState get unresolvedFile {
    if (_unresolvedFile == null) {
      _unresolvedFile = new FileState._(this, null, null, null);
      _unresolvedFile.refresh();
    }
    return _unresolvedFile;
  }

  /**
   * Return the canonical [FileState] for the given absolute [path]. The
   * returned file has the last known state since if was last refreshed.
   *
   * Here "canonical" means that if the [path] is in a package `lib` then the
   * returned file will have the `package:` style URI.
   */
  FileState getFileForPath(String path) {
    FileState file = _pathToCanonicalFile[path];
    if (file == null) {
      File resource = _resourceProvider.getFile(path);
      Source fileSource = resource.createSource();
      Uri uri = _sourceFactory.restoreUri(fileSource);
      // Try to get the existing instance.
      file = _uriToFile[uri];
      // If we have a file, call it the canonical one and return it.
      if (file != null) {
        _pathToCanonicalFile[path] = file;
        return file;
      }
      // Create a new file.
      FileSource uriSource = new FileSource(resource, uri);
      file = new FileState._(this, path, uri, uriSource);
      _uriToFile[uri] = file;
      _addFileWithPath(path, file);
      _pathToCanonicalFile[path] = file;
      file.refresh();
    }
    return file;
  }

  /**
   * Return the [FileState] for the given absolute [uri]. May return `null` if
   * the [uri] is invalid, e.g. a `package:` URI without a package name. The
   * returned file has the last known state since if was last refreshed.
   */
  FileState getFileForUri(Uri uri) {
    FileState file = _uriToFile[uri];
    if (file == null) {
      // If the external store has this URI, create a stub file for it.
      // We are given all required unlinked and linked summaries for it.
      if (externalSummaries != null) {
        String uriStr = uri.toString();
        if (externalSummaries.hasUnlinkedUnit(uriStr)) {
          file = new FileState._external(this, uri);
          _uriToFile[uri] = file;
          return file;
        }
      }

      Source uriSource = _sourceFactory.resolveUri(null, uri.toString());

      // If the URI cannot be resolved, for example because the factory
      // does not understand the scheme, return the unresolved file instance.
      if (uriSource == null) {
        _uriToFile[uri] = unresolvedFile;
        return unresolvedFile;
      }

      String path = uriSource.fullName;
      File resource = _resourceProvider.getFile(path);
      FileSource source = new FileSource(resource, uri);
      file = new FileState._(this, path, uri, source);
      _uriToFile[uri] = file;
      _addFileWithPath(path, file);
      file.refresh();
    }
    return file;
  }

  /**
   * Return the list of all [FileState]s corresponding to the given [path]. The
   * list has at least one item, and the first item is the canonical file.
   */
  List<FileState> getFilesForPath(String path) {
    FileState canonicalFile = getFileForPath(path);
    List<FileState> allFiles = _pathToFiles[path].toList();
    if (allFiles.length == 1) {
      return allFiles;
    }
    return allFiles
      ..remove(canonicalFile)
      ..insert(0, canonicalFile);
  }

  /**
   * Return `true` if there is a URI that can be resolved to the [path].
   *
   * When a file exists, but for the URI that corresponds to the file is
   * resolved to another file, e.g. a generated one in Bazel, Gn, etc, we
   * cannot analyze the original file.
   */
  bool hasUri(String path) {
    bool flag = _hasUriForPath[path];
    if (flag == null) {
      File resource = _resourceProvider.getFile(path);
      Source fileSource = resource.createSource();
      Uri uri = _sourceFactory.restoreUri(fileSource);
      Source uriSource = _sourceFactory.forUri2(uri);
      flag = uriSource.fullName == path;
      _hasUriForPath[path] = flag;
    }
    return flag;
  }

  /**
   * Remove the file with the given [path].
   */
  void removeFile(String path) {
    _uriToFile.clear();
    knownFilePaths.clear();
    _pathToFiles.clear();
    _pathToCanonicalFile.clear();
    _partToLibraries.clear();
  }

  void _addFileWithPath(String path, FileState file) {
    var files = _pathToFiles[path];
    if (files == null) {
      knownFilePaths.add(path);
      files = <FileState>[];
      _pathToFiles[path] = files;
      // Schedule the stream update.
      _addedKnownFiles.add(path);
      _scheduleKnownFilesSetChange();
    }
    files.add(file);
  }

  void _scheduleKnownFilesSetChange() {
    Duration delay = _knownFilesSetChangesDelay ?? new Duration(seconds: 1);
    _knownFilesSetChangesTimer ??= new Timer(delay, () {
      Set<String> addedFiles = _addedKnownFiles.toSet();
      Set<String> removedFiles = new Set<String>();
      _knownFilesSetChangesController
          .add(new KnownFilesSetChange(addedFiles, removedFiles));
      _addedKnownFiles.clear();
      _knownFilesSetChangesTimer = null;
    });
  }
}

@visibleForTesting
class FileSystemStateTestView {
  final FileSystemState state;

  FileSystemStateTestView(this.state);

  Set<FileState> get filesWithoutTransitiveFiles {
    return state._uriToFile.values
        .where((f) => f._transitiveFiles == null)
        .toSet();
  }

  Set<FileState> get filesWithoutTransitiveSignature {
    return state._uriToFile.values
        .where((f) => f._transitiveSignature == null)
        .toSet();
  }

  void set knownFilesDelay(Duration value) {
    state._knownFilesSetChangesDelay = value;
  }
}

/**
 * Information about changes to the known file set.
 */
class KnownFilesSetChange {
  final Set<String> added;
  final Set<String> removed;

  KnownFilesSetChange(this.added, this.removed);
}

class _FastaElementProxy implements fasta.KernelClassElement {
  @override
  final fasta.KernelInterfaceType rawType = new _FastaInterfaceTypeProxy();

  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FastaElementStoreProxy implements fasta.ElementStore {
  final _elements = <fasta.Builder, _FastaElementProxy>{};

  @override
  _FastaElementProxy operator [](fasta.Builder builder) =>
      _elements.putIfAbsent(builder, () => new _FastaElementProxy());

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FastaInterfaceTypeProxy implements fasta.KernelInterfaceType {
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
