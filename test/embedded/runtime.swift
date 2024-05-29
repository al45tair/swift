// RUN: %target-run-simple-swift(-enable-experimental-feature Embedded -parse-as-library -runtime-compatibility-version none -wmo -Xfrontend -disable-objc-interop) | %FileCheck %s
// RUN: %target-run-simple-swift(-O -enable-experimental-feature Embedded -parse-as-library -runtime-compatibility-version none -wmo -Xfrontend -disable-objc-interop) | %FileCheck %s
// RUN: %target-run-simple-swift(-Osize -enable-experimental-feature Embedded -parse-as-library -runtime-compatibility-version none -wmo -Xfrontend -disable-objc-interop) | %FileCheck %s

// REQUIRES: swift_in_compiler
// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx || OS=linux-gnu

@_extern(c, "putchar")
@discardableResult
func putchar(_: CInt) -> CInt

public func print(_ s: StaticString, terminator: StaticString = "\n") {
  var p = s.utf8Start
  while p.pointee != 0 {
    putchar(CInt(p.pointee))
    p += 1
  }
  p = terminator.utf8Start
  while p.pointee != 0 {
    putchar(CInt(p.pointee))
    p += 1
  }
}

class MyClass {
  init() { print("MyClass.init") }
  deinit { print("MyClass.deinit") }
  func foo() { print("MyClass.foo") }
}

class MySubClass: MyClass {
  override init() { print("MySubClass.init") }
  deinit { print("MySubClass.deinit") }
  override func foo() { print("MySubClass.foo") }
}

class MySubSubClass: MySubClass {
  override init() { print("MySubSubClass.init") }
  deinit { print("MySubSubClass.deinit") }
  override func foo() { print("MySubSubClass.foo") }
}

@main
struct Main {
  static var objects: [MyClass] = []
  static func main() {
    print("1") // CHECK: 1
    objects.append(MyClass())
    // CHECK: MyClass.init
    print("")

    print("2") // CHECK: 2
    objects.append(MySubClass())
    // CHECK: MySubClass.init
    // CHECK: MyClass.init
    print("")

    print("3") // CHECK: 3
    objects.append(MySubSubClass())
    // CHECK: MySubSubClass.init
    // CHECK: MySubClass.init
    // CHECK: MyClass.init
    print("")

    print("4") // CHECK: 4
    for o in objects {
      o.foo()
      // CHECK: MyClass.foo
      // CHECK: MySubClass.foo
      // CHECK: MySubSubClass.foo
    }
    print("")
    
    print("5") // CHECK: 5
    objects = []
    // CHECK: MyClass.deinit
    // CHECK: MySubClass.deinit
    // CHECK: MyClass.deinit
    // CHECK: MySubSubClass.deinit
    // CHECK: MySubClass.deinit
    // CHECK: MyClass.deinit
    print("")
  }
}
