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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
internal import Darwin
#elseif os(Windows)
internal import ucrt
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
nternal import Musl
#endif

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
internal import BacktracingImpl.OS.Darwin
#endif

#if os(Linux)
internal import BacktracingImpl.ImageFormats.Elf
#endif

/// Holds a backtrace.
public struct Backtrace: CustomStringConvertible, Sendable {
  /// The type of an address.
  ///
  /// This is used as an opaque type; if you have some Address, you
  /// can ask if it's NULL, and you can attempt to convert it to a
  /// FixedWidthInteger.
  ///
  /// This is intentionally _not_ a pointer, because you shouldn't be
  /// dereferencing them; they may refer to some other process, for
  /// example.
  public struct Address: Hashable, Codable, Sendable {
    enum Representation: Hashable, Codable, Sendable {
      case null
      case sixteenBit(UInt16)
      case thirtyTwoBit(UInt32)
      case sixtyFourBit(UInt64)
    }

    var representation: Representation

    /// The width of this address, in bits
    public var bitWidth: Int {
      switch representation {
        case .null:
          return 0
        case .sixteenBit(_):
          return 16
        case .thirtyTwoBit(_):
          return 32
        case .sixtyFourBit(_):
          return 64
      }
    }

    /// True if this address is a NULL pointer
    public var isNull: Bool {
      switch representation {
        case .null:
          return true
        case let .sixteenBit(addr):
          return addr == 0
        case let .thirtyTwoBit(addr):
          return addr == 0
        case let .sixtyFourBit(addr):
          return addr == 0
      }
    }
  }

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
    /// A program counter value.
    ///
    /// This might come from a signal handler, or an exception or some
    /// other situation in which we have captured the actual program counter.
    ///
    /// These can be directly symbolicated, as-is, with no adjustment.
    case programCounter(Address)

    /// A return address.
    ///
    /// Corresponds to a normal function call.
    ///
    /// Requires adjustment when symbolicating for a backtrace, because it
    /// points at the address after the one that triggered the child frame.
    case returnAddress(Address)

    /// An async resume point.
    ///
    /// Corresponds to an `await` in an async task.
    ///
    /// Can be directly symbolicated, as-is.
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
    ///    5: ...       <----- omittedFrames(92)
    ///    6: frame 3
    ///    7: frame 2
    ///    8: frame 1
    ///    9: frame 0   <----- top of call stack
    ///
    /// Note that the limit *includes* the discontinuity.
    ///
    /// This is good for handling cases involving deep recursion.
    case omittedFrames(Int)

    /// Indicates a discontinuity of unknown length.
    ///
    /// This can only be present at the end of a backtrace; in other cases
    /// we will know how many frames we have omitted.  For instance,
    ///
    ///    0: frame 100 <----- bottom of call stack
    ///    1: frame 99
    ///    2: frame 98
    ///    3: frame 97
    ///    4: frame 96
    ///    5: ...       <----- truncated
    case truncated

    /// The program counter, without any adjustment.
    public var originalProgramCounter: Address {
      switch self {
        case let .returnAddress(addr):
          return addr
        case let .programCounter(addr):
          return addr
        case let .asyncResumePoint(addr):
          return addr
        case .omittedFrames(_), .truncated:
          return 0
      }
    }

    /// The adjusted program counter to use for symbolication.
    public var adjustedProgramCounter: Address {
      switch self {
        case let .returnAddress(addr):
          return addr - 1
        case let .programCounter(addr):
          return addr
        case let .asyncResumePoint(addr):
          return addr
        case .omittedFrames(_), .truncated:
          return 0
      }
    }

    /// A textual description of this frame.
    public var description: String {
      switch self {
        case let .programCounter(addr):
          return "\(addr)"
        case let .returnAddress(addr):
          return "\(addr) [ra]"
        case let .asyncResumePoint(addr):
          return "\(addr) [async]"
        case .omittedFrames(_), .truncated:
          return "..."
      }
    }
  }

  /// Represents an image loaded in the process's address space
  public struct Image: CustomStringConvertible, Sendable {
    /// The name of the image (e.g. libswiftCore.dylib).
    private(set) public var name: String?

    /// The full path to the image (e.g. /usr/lib/swift/libswiftCore.dylib).
    private(set) public var path: String?

    /// The unique ID of the image, as a byte array (note that the exact number
    /// of bytes may vary, and that some images may not have a unique ID).
    ///
    /// On Darwin systems, this is the LC_UUID value; on Linux this is the
    /// build ID, which may take one of a number of forms or may not even
    /// be present.
    private(set) public var uniqueID: [UInt8]?

    /// The base address of the image.
    private(set) public var baseAddress: Backtrace.Address

    /// The end of the text segment in this image.
    private(set) public var endOfText: Backtrace.Address

    /// Provide a textual description of an Image.
    public var description: String {
      if let buildID = self.buildID {
        return "\(baseAddress)-\(endOfText) \(hex(buildID)) \(name) \(path)"
      } else {
        return "\(baseAddress)-\(endOfText) <no build ID> \(name) \(path)"
      }
    }
  }

  /// The architecture of the system that captured this backtrace.
  public var architecture: String

  /// The actual backtrace data, stored in Compact Backtrace Format.
  private var representation: [UInt8]

  /// A list of captured frame information.
  public var frames: some Sequence<Frame> {
    return CompactBacktraceFormat.Decoder(representation)
  }

  /// A list of captured images.
  ///
  /// Some backtracing algorithms may require this information, in which case
  /// it will be filled in by the `capture()` method.  Other algorithms may
  /// not, in which case it will be `nil` and you can capture an image list
  /// separately yourself using `captureImages()`.
  public var images: [Image]?

  /// Capture a backtrace from the current program location.
  ///
  /// The `capture()` method itself will not be included in the backtrace;
  /// i.e. the first frame will be the one in which `capture()` was called,
  /// and its programCounter value will be the return address for the
  /// `capture()` method call.
  ///
  /// Parameters:
  ///
  /// - algorithm:     Specifies which unwind mechanism to use.  If this
  ///                  is set to `.auto`, we will use the platform default.
  /// - limit:         The backtrace will include at most this number of
  ///                  frames; you can set this to `nil` to remove the
  ///                  limit completely if required.
  /// - offset:        Says how many frames to skip; this makes it easy to
  ///                  wrap this API without having to inline things and
  ///                  without including unnecessary frames in the backtrace.
  /// - top:           Sets the minimum number of frames to capture at the
  ///                  top of the stack.
  /// - images:        (Optional) A list of captured images.  This allows you
  ///                  to capture images once, and then generate multiple
  ///                  backtraces using a single set of captured images.
  @inline(never)
  @_semantics("use_frame_pointer")
  public static func capture(algorithm: UnwindAlgorithm = .auto,
                             limit: Int? = 64,
                             offset: Int = 0,
                             top: Int = 16,
                             images: [Image]? = nil) throws -> Backtrace {
    #if os(Linux)
    // On Linux, we need the captured images to resolve async functions
    let theImages = images ?? captureImages()
    #else
    let theImages = images
    #endif

    // N.B. We use offset+1 here to skip this frame, rather than inlining
    //      this code into the client.
    return try HostContext.withCurrentContext { ctx in
      try capture(from: ctx,
                  using: UnsafeLocalMemoryReader(),
                  images: theImages,
                  algorithm: algorithm,
                  limit: limit,
                  offset: offset + 1,
                  top: top)
    }
  }

  /// Capture a list of the images currently mapped into the calling
  /// process.
  ///
  /// @returns A list of `Image`s.
  public static func captureImages() -> [Image] {
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    return captureImages(for: mach_task_self())
    #else
    return captureImages(using: UnsafeLocalMemoryReader())
    #endif
  }

  /// Specifies options for the `symbolicated` method.
  public struct SymbolicationOptions: OptionSet {
    public let rawValue: Int

    /// Add virtual frames to show inline function calls.
    public static let showInlineFrames: SymbolicationOptions

    /// Look up source locations.
    ///
    /// This may be expensive in some cases; it may be desirable to turn
    /// this off e.g. in Kubernetes so that pods restart promptly on crash.
    public static let showSourceLocations: SymbolicationOptions

    /// Use a symbol cache, if one is available.
    public static let useSymbolCache: SymbolicationOptions

    public static let default: SymbolicationOptions = [.showInlineFrames,
                                                       .showSourceLocations,
                                                       .useSymbolCache]
  }

  /// Return a symbolicated version of the backtrace.
  ///
  /// - images:  Specifies the set of images to use for symbolication.
  ///            If `nil`, the function will look to see if the `Backtrace`
  ///            has already captured images.  If it has, those will be
  ///            used; otherwise we will capture images at this point.
  ///
  /// - options: Symbolication options; see `SymbolicationOptions`.
  public func symbolicated(with images: [Image]? = nil,
                           options: SymbolicationOptions = .default)
    -> SymbolicatedBacktrace? {
    return SymbolicatedBacktrace.symbolicate(
      backtrace: self,
      images: images,
      options: options
    )
  }

  /// Provide a textual version of the backtrace.
  public var description: String {
    var lines: [String] = []

    var n = 0
    for frame in frames {
      lines.append("\(n)\t\(frame.description)")
      switch frame {
        case let .omittedFrames(count):
          n += count
        default:
          n += 1
      }
    }

    if let images = images {
      lines.append("")
      lines.append("Images:")
      lines.append("")
      for (n, image) in images.enumerated() {
        lines.append("\(n)\t\(image.description)")
      }
    }

    return lines.joined(separator: "\n")
  }
}

// -- Capture Implementation -------------------------------------------------

extension Backtrace {
  @_spi(Internal)
  @_specialize(exported: true, kind: full, where Ctx == HostContext, Rdr == UnsafeLocalMemoryReader)
  @_specialize(exported: true, kind: full, where Ctx == HostContext, Rdr == CachingRemoteMemoryReader)
  #if os(linux)
  @_specialize(exported: true, kind: full, where Ctx == HostContext, Rdr == CachingMemserverMemoryReader)
  #endif
  public static func capture<Ctx: Context, Rdr: MemoryReader>(
    from context: Ctx,
    using memoryReader: Rdr,
    images: [Image]?,
    algorithm: UnwindAlgorithm = .auto,
    limit: Int? = 64,
    offset: Int = 0,
    top: Int = 16
  ) throws -> Backtrace {
    let addressWidth = Ctx.Address.bitWidth

    switch algorithm {
      // All of them, for now, use the frame pointer unwinder.  In the long
      // run, we should be using DWARF EH frame data for .precise.
      case .auto, .fast, .precise:
        let unwinder =
          FramePointerUnwinder(context: context,
                               images: images,
                               memoryReader: memoryReader)
          .dropFirst(offset)

        if let limit = limit {
          if limit <= 0 {
            return Backtrace(architecture: context.architecture,
                             addressWidth: addressWidth,
                             frames: [.truncated])
          }

          let realTop = top < limit ? top : limit - 1
          var iterator = unwinder.makeIterator()
          var frames: [Frame] = []

          // Capture frames normally until we hit limit
          while let frame = iterator.next() {
            if frames.count < limit {
              frames.append(frame)
              if frames.count == limit {
                break
              }
            }
          }

          if realTop == 0 {
            if let _ = iterator.next() {
              // More frames than we were asked for; replace the last
              // one with a discontinuity
              frames[limit - 1] = .truncated
            }

            return Backtrace(architecture: context.architecture,
                             addressWidth: addressWidth,
                             frames: frames)
          } else {

            // If we still have frames at this point, start tracking the
            // last `realTop` frames in a circular buffer.
            if let frame = iterator.next() {
              let topSection = limit - realTop
              var topFrames: [Frame] = []
              var topNdx = 0
              var omittedFrames = 0

              topFrames.reserveCapacity(realTop)
              topFrames.insert(contentsOf: frames.suffix(realTop - 1), at: 0)
              topFrames.append(frame)

              while let frame = iterator.next() {
                topFrames[topNdx] = frame
                topNdx += 1
                omittedFrames += 1
                if topNdx >= realTop {
                  topNdx = 0
                }
              }

              // Fix the backtrace to include a discontinuity followed by
              // the contents of the circular buffer.
              let firstPart = realTop - topNdx
              let secondPart = topNdx
              frames[topSection - 1] = .omittedFrames(omittedFrames)

              frames.replaceSubrange(topSection..<(topSection+firstPart),
                                     with: topFrames.suffix(firstPart))
              frames.replaceSubrange((topSection+firstPart)..<limit,
                                     with: topFrames.prefix(secondPart))
            }

            return Backtrace(architecture: context.architecture,
                             addressWidth: addressWidth,
                             frames: frames,
                             images: images)
          }
        } else {
          return Backtrace(architecture: context.architecture,
                           addressWidth: addressWidth,
                           frames: Array(unwinder),
                           images: images)
        }
    }
  }
}

// -- Darwin -----------------------------------------------------------------

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
extension Backtrace {

  private static func withDyldProcessInfo<T>(for task: task_t,
                                             fn: (OpaquePointer?) throws -> T)
    rethrows -> T {
    var kret = kern_return_t(KERN_SUCCESS)
    let dyldInfo = _dyld_process_info_create(task, 0, &kret)

    if kret != KERN_SUCCESS {
      fatalError("error: cannot create dyld process info")
    }

    defer {
      _dyld_process_info_release(dyldInfo)
    }

    return try fn(dyldInfo)
  }

  @_spi(Internal)
  public static func captureImages(for process: Any) -> [Image] {
    var images: [Image] = []
    let task = process as! task_t

    withDyldProcessInfo(for: task) { dyldInfo in
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

          // Find the end of the __TEXT segment
          var endOfText = machHeaderAddress + 4096

          _dyld_process_info_for_each_segment(dyldInfo, machHeaderAddress) {
            address, size, name in

            if let name = String(validatingCString: name!), name == "__TEXT" {
              endOfText = address + size
            }
          }

          images.append(Image(name: name,
                              path: pathString,
                              buildID: theUUID,
                              baseAddress: Address(machHeaderAddress),
                              endOfText: Address(endOfText)))
        }
      }
    }

    return images.sorted(by: { $0.baseAddress < $1.baseAddress })
  }
}
#endif // os(macOS) || os(iOS) || os(watchOS) || os(tvOS)

// -- Linux ------------------------------------------------------------------

#if os(linux)
extension Backtrace {
  private struct AddressRange {
    var low: Address = 0
    var high: Address = 0
  }

  @_spi(Internal)
  @_specialize(exported: true, kind: full, where M == UnsafeLocalMemoryReader)
  @_specialize(exported: true, kind: full, where M == CachingRemoteMemoryReader)
  @_specialize(exported: true, kind: full, where M == CachingLocalMemoryReader)
  public static func captureImages<M: MemoryReader>(using reader: M,
                                                    forProcess pid: Int? = nil) -> [Image] {
    var images: [Image] = []

    let path: String
    if let pid = pid {
      path = "/proc/\(pid)/maps"
    } else {
      path = "/proc/self/maps"
    }

    guard let procMaps = readString(from: path) else {
      return []
    }

    // Find all the mapped files and get high/low ranges
    var mappedFiles: [Substring:AddressRange] = [:]
    for match in ProcMapsScanner(procMaps) {
      let path = stripWhitespace(match.pathname)
      if match.inode == "0" || path == "" {
        continue
      }
      guard let start = Address(match.start, radix: 16),
            let end = Address(match.end, radix: 16) else {
        continue
      }

      if let range = mappedFiles[path] {
        mappedFiles[path] = AddressRange(low: min(start, range.low),
                                         high: max(end, range.high))
      } else {
        mappedFiles[path] = AddressRange(low: start,
                                         high: end)
      }
    }

    // Look at each mapped file to see if it's an ELF image
    for (path, range) in mappedFiles {
      // Extract the filename from path
      let name: Substring
      if let slashIndex = path.lastIndex(of: "/") {
        name = path.suffix(from: path.index(after: slashIndex))
      } else {
        name = path
      }

      // Inspect the image and extract the UUID and end of text
      guard let (endOfText, uuid) = getElfImageInfo(at: range.low,
                                                    using: reader) else {
        // Not an ELF iamge
        continue
      }

      let image = Image(name: String(name),
                        path: String(path),
                        buildID: uuid,
                        baseAddress: range.low,
                        endOfText: endOfText)

      images.append(image)
    }

    return images.sorted(by: { $0.baseAddress < $1.baseAddress })
  }
}
#endif // os(Linux)


