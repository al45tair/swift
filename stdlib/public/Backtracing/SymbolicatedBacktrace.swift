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
    /// The address that was looked-up.
    public var address: Backtrace.Address

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
    public init(address: Backtrace.Address, imageIndex: Int, imageName: String,
                rawName: String, offset: Int, sourceLocation: SourceLocation?) {
      self.address = address
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
        location = "at \(sourceLocation)"
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

  /// Construct a SymbolicatedBacktrace from a backtrace and a list of images.
  internal init(backtrace: Backtrace, images: [Backtrace.Image]?) {
    self.backtrace = backtrace

    if let images = images {
      self.images = images
    } else if let images = backtrace.images {
      self.images = images
    } else {
      self.images = Backtrace.captureImages()
    }

    /// ###TODO: Symbolicate
    self.frames = []
  }

  /// Provide a textual version of the backtrace.
  public var description: String {
    var lines: [String] = []
    for (n, frame) in frames.enumerated() {
      lines.append("\(n)\t\(frame)")
    }

    lines.append("")
    lines.append("Images:")
    lines.append("")
    for (n, image) in images.enumerated() {
      lines.append("\(n)\t\(image)")
    }

    return lines.joined(separator: "\n")
  }
}
