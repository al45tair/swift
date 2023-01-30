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
//  Defines the `SymbolicatedBacktrace` struct that represents a captured
//  backtrace with symbols.
//
//===----------------------------------------------------------------------===//

import Swift

@_implementationOnly import _SwiftBacktracingShims
@_implementationOnly import CoreFoundation

/// A symbolicated backtrace
public struct SymbolicatedBacktrace: CustomStringConvertible {
  /// The `Backtrace` from which this was constructed
  public var backtrace: Backtrace

  /// Represents a location in source code.
  ///
  /// The information in this structure comes from compiler-generated
  /// debug information and may not correspond to the current state of
  /// the filesystem --- it might even hold a path that only works
  /// from an entirely different machine.
  public struct SourceLocation: CustomStringConvertible, Sendable {
    /// The path of the source file.
    public var path: String

    /// The line number.
    public var line: Int

    /// The column number.
    public var column: Int

    /// Provide a textual description.
    public var description: String {
      if column > 0 && line > 0 {
        return "\(path):\(line):\(column)"
      } else if line > 0 {
        return "\(path):\(line)"
      } else {
        return path
      }
    }
  }

  /// Represents an individual frame in the backtrace.
  public struct Frame: CustomStringConvertible {
    /// The captured frame from the `Backtrace`.
    public var captured: Backtrace.Frame

    /// The result of doing a symbol lookup for this frame.
    public var symbol: Symbol?

    /// A textual description of this frame.
    public var description: String {
      if let symbol = symbol {
        return "\(captured) \(symbol)"
      } else {
        return captured.description
      }
    }
  }

  /// Represents a symbol we've located
  public class Symbol: CustomStringConvertible {
    /// The index of the image in which the symbol for this address is located.
    public var imageIndex: Int

    /// The name of the image in which the symbol for this address is located.
    public var imageName: String

    /// The raw symbol name, before demangling.
    public var rawName: String

    /// The demangled symbol name.
    public lazy var name: String = demangleRawName()

    /// The offset from the symbol.
    public var offset: Int

    /// The source location, if available.
    public var sourceLocation: SourceLocation?

    /// Construct a new Symbol.
    public init(imageIndex: Int, imageName: String,
                rawName: String, offset: Int, sourceLocation: SourceLocation?) {
      self.imageIndex = imageIndex
      self.imageName = imageName
      self.rawName = rawName
      self.offset = offset
      self.sourceLocation = sourceLocation
    }

    /// Demangle the raw name, if possible.
    private func demangleRawName() -> String {
      // ###FIXME: Implement this
      return rawName
    }

    /// A textual description of this symbol.
    public var description: String {
      let symPlusOffset: String

      if offset > 0 {
        symPlusOffset = "\(name) + \(offset)"
      } else if offset < 0 {
        symPlusOffset = "\(name) - \(-offset)"
      } else {
        symPlusOffset = name
      }

      let location: String
      if let sourceLocation = sourceLocation {
        location = " at \(sourceLocation)"
      } else {
        location = ""
      }

      return "[\(imageIndex)] \(imageName) \(symPlusOffset)\(location)"
    }
  }

  /// A list of captured frame information.
  public var frames: [Frame]

  /// A list of images found in the process.
  public var images: [Backtrace.Image]

  /// Shared cache information.
  public var sharedCacheInfo: Backtrace.SharedCacheInfo

  /// Construct a SymbolicatedBacktrace from a backtrace and a list of images.
  private init(backtrace: Backtrace, images: [Backtrace.Image],
               sharedCacheInfo: Backtrace.SharedCacheInfo,
               frames: [Frame]) {
    self.backtrace = backtrace
    self.images = images
    self.sharedCacheInfo = sharedCacheInfo
    self.frames = frames
  }

  #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
  /// Convert a build ID to a CFUUIDBytes.
  private static func uuidBytesFromBuildID(_ buildID: [UInt8]) -> CFUUIDBytes {
    var result = CFUUIDBytes()
    withUnsafeMutablePointer(to: &result) {
      $0.withMemoryRebound(to: UInt8.self,
                           capacity: MemoryLayout<CFUUIDBytes>.size) {
        let bp = UnsafeMutableBufferPointer(start: $0,
                                            count: MemoryLayout<CFUUIDBytes>.size)
        _ = bp.initialize(from: buildID)
      }
    }
    return result
  }

  /// Create a symbolicator.
  private static func withSymbolicator<T>(images: [Backtrace.Image],
                                          sharedCacheInfo: Backtrace.SharedCacheInfo,
                                          fn: (CSSymbolicatorRef) throws -> T) rethrows -> T {
    let binaryImageList = images.map{ image in
      BinaryImageInformation(
        base: image.baseAddress,
        extent: image.endOfText,
        uuid: uuidBytesFromBuildID(image.buildID!),
        arch: HostContext.coreSymbolicationArchitecture,
        path: image.path,
        relocations: [
          BinaryRelocationInformation(
            base: image.baseAddress,
            extent: image.endOfText,
            name: "__TEXT"
          )
        ],
        flags: 0
      )
    }

    let symbolicator = CSSymbolicatorCreateWithBinaryImageList(
      binaryImageList, 0, nil
    )

    defer { CSRelease(symbolicator) }

    return try fn(symbolicator)
  }
  #endif

  /// Actually symbolicate.
  internal static func symbolicate(backtrace: Backtrace,
                                   images: [Backtrace.Image]?,
                                   sharedCacheInfo: Backtrace.SharedCacheInfo?)
    -> SymbolicatedBacktrace? {

    let theImages: [Backtrace.Image]
    if let images = images {
      theImages = images
    } else if let images = backtrace.images {
      theImages = images
    } else {
      theImages = Backtrace.captureImages()
    }

    let theCacheInfo: Backtrace.SharedCacheInfo
    if let sharedCacheInfo = sharedCacheInfo {
      theCacheInfo = sharedCacheInfo
    } else if let sharedCacheInfo = backtrace.sharedCacheInfo {
      theCacheInfo = sharedCacheInfo
    } else {
      theCacheInfo = Backtrace.captureSharedCacheInfo()
    }

    var frames: [Frame] = []

    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    withSymbolicator(images: theImages,
                     sharedCacheInfo: theCacheInfo) { symbolicator in
      for frame in backtrace.frames {
        switch frame {
          case .omittedFrames(_), .truncated:
            print("  is omitted/truncated")
            frames.append(Frame(captured: frame, symbol: nil))
          default:
            let address = frame.adjustedProgramCounter
            let owner
              = CSSymbolicatorGetSymbolOwnerWithAddressAtTime(symbolicator,
                                                              address,
                                                              kCSBeginningOfTime)

            if CSIsNull(owner) {
              frames.append(Frame(captured: frame, symbol: nil))
            } else {
              let symbol = CSSymbolOwnerGetSymbolWithAddress(owner, address)

              let theSymbol: Symbol

              if CSIsNull(symbol) {
                frames.append(Frame(captured: frame, symbol: nil))
              } else {
                let rawName = CSSymbolGetMangledName(symbol) ?? ""
                let name = CSSymbolGetName(symbol) ?? ""
                let range = CSSymbolGetRange(symbol)

                // ###TODO: inline frames

                let sourceInfo = CSSymbolOwnerGetSourceInfoWithAddress(owner,
                                                                       address)
                let location: SourceLocation?
                if !CSIsNull(sourceInfo) {
                  let path = CSSourceInfoGetPath(sourceInfo) ?? ""
                  let line = CSSourceInfoGetLineNumber(sourceInfo)
                  let column = CSSourceInfoGetColumn(sourceInfo)

                  location = SourceLocation(
                    path: path,
                    line: Int(line),
                    column: Int(column)
                  )
                } else {
                  location = nil
                }

                let imageBase = CSSymbolOwnerGetBaseAddress(owner)
                var imageIndex = -1
                var imageName = ""
                for (ndx, image) in theImages.enumerated() {
                  if image.baseAddress == imageBase {
                    imageIndex = ndx
                    imageName = image.name
                    break
                  }
                }

                theSymbol = Symbol(imageIndex: imageIndex,
                                   imageName: imageName,
                                   rawName: rawName,
                                   offset: Int(address - range.location),
                                   sourceLocation: location)
                theSymbol.name = name

                frames.append(Frame(captured: frame, symbol: theSymbol))
              }
            }
        }
      }
    }
    #else
    frames = backtrace.frames.map{ Frame(captured: $0, symbol: nil) }
    #endif

    return SymbolicatedBacktrace(backtrace: backtrace,
                                 images: theImages,
                                 sharedCacheInfo: theCacheInfo,
                                 frames: frames)
  }

  /// Provide a textual version of the backtrace.
  public var description: String {
    var lines: [String] = []

    var n = 0
    for frame in frames {
      lines.append("\(n)\t\(frame)")
      switch frame.captured {
        case let .omittedFrames(count):
          n += count
        default:
          n += 1
      }
    }

    lines.append("")
    lines.append("Images:")
    lines.append("")
    for (n, image) in images.enumerated() {
      lines.append("\(n)\t\(image)")
    }

    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    lines.append("")
    lines.append("Shared Cache:")
    lines.append("")
    lines.append("    UUID: \(hex(sharedCacheInfo.uuid))")
    lines.append("    Base: \(hex(sharedCacheInfo.baseAddress))")
    lines.append("  Active: \(!sharedCacheInfo.noCache)")
    #endif

    return lines.joined(separator: "\n")
  }
}
