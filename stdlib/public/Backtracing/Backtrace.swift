//===--- Backtrace.swift --------------------------------------*- swift -*-===//
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
//  Defines the `Backtrace` struct that represents a captured backtrace.
//
//===----------------------------------------------------------------------===//

import Swift

#if os(macOS) || os(iOS) || os(watchOS)

@_implementationOnly import Darwin.Mach
@_implementationOnly import _SwiftBacktracingShims

#endif

/// Holds a backtrace.
public struct Backtrace: CustomStringConvertible, Sendable {
  /// The type of an address.
  ///
  /// This will be `UInt32` or `UInt64` on current platforms.
  #if arch(x86_64) || arch(arm64)
  public typealias Address = UInt64
  #elseif arch(i386) || arch(arm)
  public typealias Address = UInt32
  #else
  #error("You need to fill this in for your architecture.")
  #endif

  /// The unwind algorithm to use.
  public enum UnwindAlgorithm {
    /// Choose the most appropriate for the platform.
    case auto

    /// Use the fastest viable method.
    ///
    /// Typically this means walking the frame pointers.
    case fast

    /// Use the most precise available method.
    ///
    /// On Darwin and on ELF platforms, this will use EH unwind
    /// information.  On Windows, it will use Win32 API functions.
    case precise
  }

  /// Represents an individual frame in a backtrace.
  public enum Frame: CustomStringConvertible, Sendable {
    /// An accurate program counter.
    ///
    /// This might come from a signal handler, or an exception or some
    /// other situation in which we have captured the actual program counter.
    case programCounter(Address)

    /// A return address.
    ///
    /// Corresponds to a call from a normal function.
    case returnAddress(Address)

    /// An accurate program counter in an async context.
    case programCounterInAsync(Address)

    /// A return address to an async context.
    ///
    /// Corresponds to a call from an async task.
    case returnAddressInAsync(Address)

    /// An async resume point.
    ///
    /// Corresponds to an `await` in an async task.
    case asyncResumePoint(Address)

    /// Indicates a discontinuity in the backtrace.
    ///
    /// This occurs when you set a limit and a minimum number of frames at
    /// the top.  For example, if you set a limit of 10 frames and a minimum
    /// of 4 top frames, but the backtrace generated 100 frames, you will see
    ///
    ///    0: frame 100 <----- bottom of call stack
    ///    1: frame 99
    ///    2: frame 98
    ///    3: frame 97
    ///    4: frame 96
    ///    5: ...       <----- discontinuity
    ///    6: frame 3
    ///    7: frame 2
    ///    8: frame 1
    ///    9: frame 0   <----- top of call stack
    ///
    /// Note that the limit *includes* the discontinuity.
    ///
    /// This is good for handling cases involving deep recursion.
    case discontinuity

    /// The adjusted program counter to use for symbolication.
    public var adjustedProgramCounter: Address {
      switch self {
        case let .returnAddress(addr):
          return addr - 1
        case let .returnAddressInAsync(addr):
          return addr - 1
        case let .programCounter(addr):
          return addr
        case let .programCounterInAsync(addr):
          return addr
        case let .asyncResumePoint(addr):
          return addr
        case .discontinuity:
          return 0
      }
    }

    /// A textual description of this frame.
    public var description: String {
      switch self {
        case let .programCounter(addr):
          return "\(hex(addr))"
        case let .returnAddress(addr):
          return "\(hex(addr)) [ra]"
        case let .returnAddressInAsync(addr):
          return "\(hex(addr)) [ra] [async]"
        case let .programCounterInAsync(addr):
          return "\(hex(addr)) [async]"
        case let .asyncResumePoint(addr):
          return "\(hex(addr)) [async]"
        case .discontinuity:
          return "..."
      }
    }
  }

  /// Represents an image loaded in the process's address space
  public struct Image: Sendable {
    /// The name of the image (e.g. libswiftCore.dylib).
    public var name: String

    /// The full path to the image (e.g. /usr/lib/swift/libswiftCore.dylib).
    public var path: String

    /// The build ID of the image, as a byte array (note that the exact number
    /// of bytes may vary, and that some images may not have a build ID).
    public var buildID: [UInt8]?

    /// The base address of the image.
    public var baseAddress: Backtrace.Address

    /// Provide a textual description of an Image.
    public var description: String {
      if let buildID = self.buildID {
        return "\(hex(baseAddress)) \(hex(buildID)) \(name) \(path)"
      } else {
        return "\(hex(baseAddress)) <no build ID> \(name) \(path)"
      }
    }
  }

  /// A list of captured frame information.
  public var frames: [Frame]

  /// A list of captured images.
  ///
  /// Some backtracing algorithms may require this information, in which case
  /// it will be filled in by the `capture()` method.  Other algorithms may
  /// not, in which case it will be empty and you can capture an image list
  /// separately yourself using `captureImages()`.
  public var images: [Image]?

  /// Capture a backtrace from the current program location.
  ///
  /// The `capture()` method itself will not be included in the backtrace;
  /// i.e. the first frame will be the one in which `capture()` was called,
  /// and its programCounter value will be the return address for the
  /// `capture()` method call.
  ///
  /// @param algorithm     Specifies which unwind mechanism to use.  If this
  ///                      is set to `.auto`, we will use the platform default.
  /// @param limit         The backtrace will include at most this number of
  ///                      frames; you can set this to `nil` to remove the
  ///                      limit completely if required.
  /// @param offset        Says how many frames to skip; this makes it easy to
  ///                      wrap this API without having to inline things and
  ///                      without including unnecessary frames in the backtrace.
  /// @param top           Sets the minimum number of frames to capture at the
  ///                      top of the stack.
  ///
  /// @returns A new `Backtrace` struct.
  public static func capture(algorithm: UnwindAlgorithm = .auto,
                             limit: Int? = 4096,
                             offset: Int = 0,
                             top: Int = 0) throws -> Backtrace {
    var frames: [Frame]
    switch algorithm {
      // ###FIXME: .precise should be using DWARF EH
      case .auto, .fast, .precise:
        frames = HostContext.withCurrentContext { ctx in
          let unwinder =
            FramePointerUnwinder(context: ctx,
                                 memoryReader: UnsafeLocalMemoryReader())
            .dropFirst(offset)

          if let limit = limit {
            if limit == 0 {
              return [Frame.discontinuity]
            }

            let realTop = top < limit ? top : limit - 1
            var iterator = unwinder.makeIterator()
            var result: [Frame] = []

            // Capture frames normally until we hit limit
            while let frame = iterator.next() {
              if result.count < limit {
                result.append(frame)
                if result.count == limit {
                  break
                }
              }
            }

            if realTop == 0 {
              if let _ = iterator.next() {
                // More frames than we were asked for; replace the last
                // one with a discontinuity
                result[limit - 1] = .discontinuity
              }

              return result
            } else {

              // If we still have frames at this point, start tracking the
              // last `realTop` frames in a circular buffer.
              if let frame = iterator.next() {
                let topSection = limit - realTop
                var topFrames: [Frame] = []
                var topNdx = 0

                topFrames.reserveCapacity(realTop)
                topFrames.insert(contentsOf: result.suffix(realTop - 1), at: 0)
                topFrames.append(frame)

                while let frame = iterator.next() {
                  topFrames[topNdx] = frame
                  topNdx += 1
                  if topNdx >= realTop {
                    topNdx = 0
                  }
                }

                // Fix the backtrace to include a discontinuity followed by
                // the contents of the circular buffer.
                let firstPart = realTop - topNdx
                let secondPart = topNdx
                result[topSection - 1] = .discontinuity

                result.replaceSubrange(topSection..<(topSection+firstPart),
                                       with: topFrames.suffix(firstPart))
                result.replaceSubrange((topSection+firstPart)..<limit,
                                       with: topFrames.prefix(secondPart))
              }

              return result
            }
          } else {
            return Array(unwinder)
          }
        }
    }

    return Backtrace(frames: frames)
  }

  /// Capture the a list of the images currently mapped into the calling
  /// process.
  ///
  /// @returns A list of `Image`s.
  public static func captureImages() -> [Image] {
    var images: [Image] = []

    #if os(macOS) || os(iOS) || os(watchOS)
    var kret: kern_return_t = KERN_SUCCESS
    let dyldInfo = _dyld_process_info_create(mach_task_self_, 0, &kret)

    if kret != KERN_SUCCESS {
      print("warning: unable to create dyld process info; cannot fetch images")
      return []
    }

    defer {
      _dyld_process_info_release(dyldInfo)
    }

    _dyld_process_info_for_each_image(dyldInfo) {
      (machHeaderAddress, uuid, path) in

      if let path = path, let uuid = uuid {
        let pathString = String(cString: path)
        let theUUID = Array(UnsafeBufferPointer(start: uuid,
                                                count: MemoryLayout<uuid_t>.size))
        let name: String
        if let slashIndex = pathString.lastIndex(of: "/") {
          name = String(pathString.suffix(from:
                                            pathString.index(after:slashIndex)))
        } else {
          name = pathString
        }
        images.append(Image(name: name,
                            path: pathString,
                            buildID: theUUID,
                            baseAddress: machHeaderAddress))
      }
    }
    #endif // os(macOS) || os(iOS) || os(watchOS)

    return images.sorted(by: { $0.baseAddress < $1.baseAddress })
  }

  /// Return a symbolicated version of the backtrace.
  ///
  /// @param with   Specifies the set of images to use for symbolication.
  ///               If `nil`, the function will look to see if the `Backtrace`
  ///               has already captured images.  If it has, those will be
  ///               used; otherwise we will capture images at this point.
  ///
  /// @returns A new `SymbolicatedBacktrace`.
  public func symbolicated(with images: [Image]? = nil) -> SymbolicatedBacktrace {
    return SymbolicatedBacktrace(backtrace: self, images: images)
  }

  /// Provide a textual version of the backtrace.
  public var description: String {
    var lines: [String] = []
    for (n, frame) in frames.enumerated() {
      lines.append("\(n)\t\(frame)")
    }

    if let images = images {
      lines.append("")
      lines.append("Images:")
      lines.append("")
      for (n, image) in images.enumerated() {
        lines.append("\(n)\t\(image)")
      }
    }

    return lines.joined(separator: "\n")
  }
}
