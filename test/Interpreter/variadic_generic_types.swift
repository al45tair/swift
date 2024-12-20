// RUN: %target-run-simple-swift(-enable-experimental-feature VariadicGenerics) | %FileCheck %s

// REQUIRES: executable_test

// Because of -enable-experimental-feature VariadicGenerics
// REQUIRES: asserts

struct G<each T> {
  func makeTuple() {
    print((repeat (Array<each T>)).self)
  }
}

// CHECK: ()
G< >().makeTuple()

// CHECK: (Array<Int>, Array<String>, Array<Float>)
G<Int, String, Float>().makeTuple()
