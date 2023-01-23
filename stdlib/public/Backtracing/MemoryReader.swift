//===--- MemoryReader.swift -----------------------------------*- swift -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
//  Provides the ability to read memory, both in the current process and
//  remotely.
//
//===----------------------------------------------------------------------===//

@_implementationOnly import _SwiftBacktracingShims

internal struct UnsafeLocalMemoryReader {
  public typealias Address = UInt

  public func fetch<T>(from address: Address,
                       into buffer: UnsafeMutableBufferPointer<T>) -> Bool {
    let basePointer = UnsafePointer<T>(bitPattern: address)
    let from = UnsafeBufferPointer<T>(start: basePointer,
                                      count: buffer.count)
    for n in 0..<buffer.count {
      buffer[n] = from[n]
    }

    return true
  }
}

#if os(macOS) || os(iOS) || os(watchOS)
@_implementationOnly import Darwin.Mach

internal struct RemoteMemoryReadError: Error {
  var error: kern_return_t
  var address: UInt64
  var size: UInt64
}

internal struct RemoteMemoryReader {
  public typealias Address = UInt64

  private var task: task_t

  public init(task: task_t) {
    self.task = task
  }

  public func fetch<T>(from address: Address,
                       into buffer: UnsafeMutableBufferPointer<T>) -> Bool {
    let size = mach_vm_size_t(MemoryLayout<T>.stride * buffer.count)
    var sizeOut = mach_vm_size_t(0)
    let kr = mach_vm_read_overwrite(task,
                                    mach_vm_address_t(address),
                                    mach_vm_size_t(size),
                                    unsafeBitCast(buffer.baseAddress,
                                                  to: mach_vm_address_t.self),
                                    &sizeOut)

    return kr == KERN_SUCCESS
  }
}

internal struct LocalMemoryReader {
  public typealias Address = UInt64

  var reader = RemoteMemoryReader(task: mach_task_self_)

  public func fetch<T>(from address: Address,
                       into buffer: UnsafeMutableBufferPointer<T>) -> Bool {
    return reader.fetch(from: address, into: buffer)
  }
}
#endif
