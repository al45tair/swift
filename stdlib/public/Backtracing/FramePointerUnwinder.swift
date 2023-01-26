//===--- FramePointerUnwinder.swift ---------------------------*- swift -*-===//
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
//  Unwind the stack by chasing the frame pointer.
//
//===----------------------------------------------------------------------===//

import Swift

// @available(SwiftStdlib 5.1, *)
@_silgen_name("swift_task_getCurrent")
func _getCurrentAsyncTask() -> Builtin.NativeObject?

@_spi(Unwinders)
public struct FramePointerUnwinder<C: Context, M: MemoryReader>: Sequence, IteratorProtocol {
  public typealias Context = C
  public typealias MemoryReader = M
  public typealias Address = MemoryReader.Address

  var pc: Address
  var fp: Address
  var asyncContext: Address
  var first: Bool
  var isAsync: Bool

  var reader: MemoryReader

  public init(context: Context, memoryReader: MemoryReader) {
    pc = Address(context.programCounter)
    fp = Address(context.framePointer)
    first = true
    isAsync = false
    asyncContext = 0
    reader = memoryReader
  }

  private func isAsyncFrame() -> Bool {
    #if (os(macOS) || os(iOS) || os(watchOS)) && (arch(arm64) || arch(arm64_32) || arch(x86_64))
    // On Darwin, we borrow a bit of the frame pointer to indicate async
    // stack frames
    return (fp & (1 << 60)) != 0 && _getCurrentAsyncTask() != nil
    #else
    return false
    #endif
  }

  private mutating func fetchAsyncContext() -> Bool {
    let strippedFp = Context.stripPtrAuth(address: Context.Address(fp))

    do {
      asyncContext = try reader.fetch<Address>(from: Address(strippedFp - 8))
      return true
    } catch {
      return false
    }
  }

  public mutating func next() -> Backtrace.Frame? {
    if isAsync {
      var next: Address = 0
      let strippedCtx
        = Address(Context.stripPtrAuth(address: Context.Address(asyncContext)))

      if strippedCtx == 0 {
        return nil
      }

      #if arch(arm64_32)

      // On arm64_32, the two pointers at the start of the context are 32-bit,
      // although the stack layout is identical to vanilla arm64
      do {
        var next32 = try reader.fetch<UInt32>(from: strippedCtx)
        var pc32 = try reader.fetch<UInt32>(from: strippedCtx + 4)

        next = Address(next32)
        pc = Address(pc32)
      } catch {
        return nil
      }
      #else

      // Otherwise it's two 64-bit words
      do {
        next = try reader.fetch<Address>(from: strippedCtx)
        pc = try reader.fetch<Address>(from: strippedCtx + 8)
      } catch {
        return nil
      }

      #endif

      asyncContext = next

      return .asyncResumePoint(Backtrace.Address(pc))
    }

    if first {
      first = false
      isAsync = isAsyncFrame()

      if isAsync {
        if !fetchAsyncContext() {
          return nil
        }

        return .programCounterInAsync(Backtrace.Address(pc))
      }

      return .programCounter(Backtrace.Address(pc))
    }

    // Try to read the next fp/pc pair
    var next: Address = 0
    let strippedFp = Context.stripPtrAuth(address: Context.Address(fp))

    if strippedFp == 0
     || !Context.isAlignedForStack(framePointer: strippedFp) {
      return nil
    }

    do {
      pc = try reader.fetch<Address>(from: (Address(strippedFp)
                                              + Address(MemoryLayout<Address>.size)))
      next = try reader.fetch<Address>(from: Address(strippedFp))
    } catch {
      return nil
    }

    if next <= fp {
      return nil
    }

    fp = next
    isAsync = isAsyncFrame()

    if isAsync {
      if !fetchAsyncContext() {
        return nil
      }

      return .returnAddressInAsync(Backtrace.Address(pc))
    }

    return .returnAddress(Backtrace.Address(pc))
  }
}
