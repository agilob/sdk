// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Test derived from language_2/generic_methods_dynamic_test/05

/*class: global#JSArray:deps=[EmptyIterable,List,ListIterable,SubListIterable],explicit=[JSArray],needsArgs*/
/*class: global#List:deps=[C.bar,EmptyIterable,Iterable,JSArray,ListIterable],explicit=[List,List<B>],needsArgs*/

import "package:expect/expect.dart";

class A {}

/*class: B:explicit=[List<B>]*/
class B {}

class C {
  /*element: C.bar:needsArgs,selectors=[Selector(call, bar, arity=1, types=1)]*/
  List<T> bar<T>(Iterable<T> t) => <T>[t.first];
}

main() {
  C c = new C();
  dynamic x = c.bar<B>(<B>[new B()]);
  Expect.isTrue(x is List<B>);
}
