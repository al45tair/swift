//===--- BacktraceFormatter.swift -----------------------------*- swift -*-===//
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
//  Provides functionality to format backtraces, with various additional
//  options.
//
//===----------------------------------------------------------------------===//

import Swift

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
@_implementationOnly import Darwin
#elseif os(Windows)
@_implementationOnly import MSVCRT
#elseif os(Linux)
@_implementationOnly import Glibc
#endif

@_implementationOnly import _SwiftBacktracingShims

/// A backtrace formatting theme.
@_spi(Formatting)
public protocol BacktraceFormattingThemeProtocol {
  func frameIndex(_ s: String) -> String
  func programCounter(_ s: String) -> String
  func frameAttribute(_ s: String) -> String
  func symbol(_ s: String) -> String
  func offset(_ s: String) -> String
  func sourceLocation(_ s: String) -> String
  func lineNumber(_ s: String) -> String
  func code(_ s: String) -> String
  func crashedLine(_ s: String) -> String
  func crashLocation(_ s: String) -> String
  func imageName(_ s: String) -> String
}

extension BacktraceFormattingThemeProtocol {
  public func frameIndex(_ s: String) -> String { return s }
  public func programCounter(_ s: String) -> String { return s }
  public func frameAttribute(_ s: String) -> String { return "[\(s)]" }
  public func symbol(_ s: String) -> String { return s }
  public func offset(_ s: String) -> String { return s }
  public func sourceLocation(_ s: String) -> String { return s }
  public func lineNumber(_ s: String) -> String { return s }
  public func code(_ s: String) -> String { return s }
  public func crashedLine(_ s: String) -> String { return s }
  public func crashLocation(_ s: String) -> String { return s }
  public func imageName(_ s: String) -> String { return s }
}

/// Options for backtrace formatting.
///
/// This is used by chaining modifiers, e.g. .theme(.color).showSourceCode().
@_spi(Formatting)
public struct BacktraceFormattingOptions {
  var _theme: BacktraceFormattingThemeProtocol = BacktraceFormatter.Themes.plain
  var _showSourceCode: Bool = false
  var _sourceContextLines: Int = 2
  var _showAddresses: Bool = true
  var _showImages: Bool = true
  var _showImageNames: Bool = true
  var _showFrameAttributes: Bool = true
  var _skipRuntimeFailures: Bool = false
  var _sanitizePaths: Bool = true
  var _demangle: Bool = true
  var _width: Int = 80

  /// Theme to use for formatting.
  ///
  /// @param theme  A `BacktraceFormattingTheme` structure.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func theme(_ theme: BacktraceFormattingThemeProtocol) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().theme(theme)
  }
  public func theme(_ theme: BacktraceFormattingThemeProtocol) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._theme = theme
    return newOptions
  }

  /// Enable or disable the display of source code in the backtrace.
  ///
  /// @param enabled       Whether or not to enable source code.
  ///
  /// @param contextLines  The number of lines of context either side of the
  ///                      line associated with the backtrace frame.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func showSourceCode(_ enabled: Bool = true, contextLines: Int = 2) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().showSourceCode(enabled,
                                                       contextLines: contextLines)
  }
  public func showSourceCode(_ enabled: Bool = true, contextLines: Int = 2) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._showSourceCode = enabled
    newOptions._sourceContextLines = contextLines
    return newOptions
  }

  /// Enable or disable the display of raw addresses.
  ///
  /// @param enabled  If false, we will only display a raw address in the
  ///                 backtrace if we haven't been able to symbolicate.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func showAddresses(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().showAddresses(enabled)
  }
  public func showAddresses(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._showAddresses = enabled
    return newOptions
  }

  /// Enable or disable the display of the image list.
  ///
  /// @param enabled  Says whether or not to output the image list.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func showImages(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().showImages(enabled)
  }
  public func showImages(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._showImages = enabled
    return newOptions
  }

  /// Enable or disable the display of image names in the frame list.
  ///
  /// @param enabled  If true, we will display the name of the image for
  ///                 each frame.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func showImageNames(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().showImageNames(enabled)
  }
  public func showImageNames(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._showImageNames = enabled
    return newOptions
  }

  /// Enable or disable the display of frame attributes in the frame list.
  ///
  /// @param enabled  If true, we will display the frame attributes.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func showFrameAttributes(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().showFrameAttributes(enabled)
  }
  public func showFrameAttributes(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._showFrameAttributes = enabled
    return newOptions
  }

  /// Set whether or not to show Swift runtime failure frames.
  ///
  /// @param enabled  If true, we will skip Swift runtime failure frames.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func skipRuntimeFailures(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().skipRuntimeFailures(enabled)
  }
  public func skipRuntimeFailures(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._skipRuntimeFailures = enabled
    return newOptions
  }

  /// Enable or disable path sanitization.
  ///
  /// This is intended to avoid leaking PII into crash logs.
  ///
  /// @param enabled  If true, paths will be sanitized.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func sanitizePaths(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().sanitizePaths(enabled)
  }
  public func sanitizePaths(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._sanitizePaths = enabled
    return newOptions
  }

  /// Set whether we show mangled or demangled names.
  ///
  /// @param enabled  If true, we show demangled names if we have them.
  ///
  /// @returns A new `BacktraceFormattingOptions` structure.
  public static func demangle(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().demangle(enabled)
  }
  public func demangle(_ enabled: Bool = true) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._demangle = enabled
    return newOptions
  }

  /// Set the output width.
  ///
  /// @param width  The output width in characters.  This is only used to
  ///               highlight information, and defaults to 80.
  ///
  /// returns A new `BacktraceFormattingOptions` structure.
  public static func width(_ width: Int) -> BacktraceFormattingOptions {
    return BacktraceFormattingOptions().width(width)
  }
  public func width(_ width: Int) -> BacktraceFormattingOptions {
    var newOptions = self
    newOptions._width = width
    return newOptions
  }
}

/// Return the width of a given Unicode.Scalar.
///
/// It would be nice to have the Unicode width data, which would let us do
/// a better job of this.
private func measure(_ ch: Unicode.Scalar) -> Int {
  if ch.isASCII {
    return 1
  }

  if #available(macOS 10.12.2, *) {
    if ch.properties.isEmoji {
      return 2
    }
  } else if ch.value >= 0x1f100 && ch.value <= 0x1fb00 {
    return 2
  }

  if ch.properties.isIdeographic
       && !(ch.value >= 0xff61 && ch.value <= 0xffdc)
       && !(ch.value >= 0xffe8 && ch.value <= 0xffee) {
    return 2
  }

  if ch.properties.canonicalCombiningClass.rawValue != 0 {
    return 0
  }

  switch ch.properties.generalCategory {
    case .control, .nonspacingMark:
      return 0
    default:
      return 1
  }
}

/// Compute the width of the given string, ignoring CSI formatting codes.
private enum MeasureState {
  // Normal state
  case normal

  // Start of an escape
  case escape

  // In a CSI escape
  case csi
}

private func measure<S: StringProtocol>(_ s: S) -> Int {
  var totalWidth = 0
  var state: MeasureState = .normal

  for ch in s.unicodeScalars {
    switch state {
      case .normal:
        if ch.value == 27 {
          // This is an escape sequence
          state = .escape
        } else {
          totalWidth += measure(ch)
        }
      case .escape:
        if ch.value == 0x5b {
          state = .csi
        } else {
          state = .normal
        }
      case .csi:
        if ch.value >= 0x40 && ch.value <= 0x7e {
          state = .normal
        }
    }
  }
  return totalWidth
}

/// Pad the given string to the given width using spaces.
private enum Alignment {
  case left
  case right
  case center
}

private func pad(_ s: String, to width: Int,
                 aligned alignment: Alignment = .left) -> String {
  let currentWidth = measure(s)
  let padding = max(width - currentWidth, 0)

  switch alignment {
    case .left:
      let spaces = String(repeating: " ", count: padding)

      return s + spaces
    case .right:
      let spaces = String(repeating: " ", count: padding)

      return spaces + s
    case .center:
      let left = padding / 2
      let right = padding - left
      let leftSpaces = String(repeating: " ", count: left)
      let rightSpaces = String(repeating: " ", count: right)

      return "\(leftSpaces)\(s)\(rightSpaces)"
  }
}

/// Untabify the given string, assuming tabs of the specified size.
///
/// @param s         The string to untabify.
/// @param tabWidth  The tab width to assume (default 8).
///
/// @returns A string with all the tabs replaced with appropriate numbers
///          of spaces.
private func untabify(_ s: String, tabWidth: Int = 8) -> String {
  var result: String = ""
  var first = true
  for chunk in s.split(separator: "\t", omittingEmptySubsequences: false) {
    if first {
      first = false
    } else {
      let toTabStop = tabWidth - measure(result) % tabWidth
      result += String(repeating: " ", count: toTabStop)
    }
    result += chunk
  }
  return result
}

/// Sanitize a path to remove usernames, volume names and so on.
///
/// The point of this function is to try to remove anything that might
/// contain PII before it ends up in a log file somewhere.
///
/// @param path  The path to sanitize.
///
/// @returns A string containing the sanitized path.
private func sanitizePath(_ path: String) -> String {
  #if os(macOS)
  return CRCopySanitizedPath(path,
                             kCRSanitizePathGlobAllTypes
                               | kCRSanitizePathKeepFile)
  #else
  // For now, on non-macOS systems, do nothing
  return path
  #endif
}

/// Responsible for formatting backtraces.
@_spi(Formatting)
public struct BacktraceFormatter {

  /// The formatting options to apply when formatting data.
  public var options: BacktraceFormattingOptions

  public struct Themes {
    /// A plain formatting theme.
    public struct PlainTheme: BacktraceFormattingThemeProtocol {
    }

    /// An ANSI color formatting theme.
    public struct AnsiColorTheme: BacktraceFormattingThemeProtocol {
      public func frameIndex(_ s: String) -> String {
        return "\u{1b}[90m\(s)\u{1b}[39m"
      }
      public func programCounter(_ s: String) -> String {
        return "\u{1b}[32m\(s)\u{1b}[39m"
      }
      public func frameAttribute(_ s: String) -> String {
        return "\u{1b}[34m[\(s)]\u{1b}[39m"
      }

      public func symbol(_ s: String) -> String {
        return "\u{1b}[95m\(s)\u{1b}[39m"
      }
      public func offset(_ s: String) -> String {
        return "\u{1b}[37m\(s)\u{1b}[39m"
      }
      public func sourceLocation(_ s: String) -> String {
        return "\u{1b}[33m\(s)\u{1b}[39m"
      }
      public func lineNumber(_ s: String) -> String {
        return "\u{1b}[90m\(s)\u{1b}[39m"
      }
      public func code(_ s: String) -> String {
        return "\(s)"
      }
      public func crashedLine(_ s: String) -> String {
        return "\u{1b}[48;5;234m\(s)\u{1b}[49m"
      }
      public func crashLocation(_ s: String) -> String {
        return "\u{1b}[91m\(s)\u{1b}[39m"
      }
      public func imageName(_ s: String) -> String {
        return "\u{1b}[36m\(s)\u{1b}[39m"
      }
    }

    public static let plain = PlainTheme()
    public static let color = AnsiColorTheme()
  }

  public init(_ options: BacktraceFormattingOptions) {
    self.options = options
  }

  enum TableRow {
    case columns([String])
    case raw(String)
  }

  /// Output a table with each column nicely aligned.
  ///
  /// @param rows  An array of table rows, each of which holds an array
  ///              of table columns.
  ///
  /// @result A `String` containing the formatted table.
  private static func formatTable(_ rows: [TableRow],
                                  alignments: [Alignment] = []) -> String {
    // Work out how many columns we have
    let columns = rows.map{
      if case let .columns(columns) = $0 {
        return columns.count
      } else {
        return 0
      }
    }.reduce(0, max)

    // Now compute their widths
    var widths = Array(repeating: 0, count: columns)
    for row in rows {
      if case let .columns(columns) = row {
        for (n, width) in columns.lazy.map(measure).enumerated() {
          widths[n] = max(widths[n], width)
        }
      }
    }

    // Generate lines for the table
    var lines: [String] = []
    for row in rows {
      switch row {
        case let .columns(columns):
          let line = columns.enumerated().map{ n, column in
            let alignment = n < alignments.count ? alignments[n] : .left
            return pad(column, to: widths[n], aligned: alignment)
          }.joined(separator: " ")

          lines.append(line)
        case let .raw(line):
          lines.append(line)
      }
    }

    return lines.joined(separator: "\n")
  }

  /// Format the frame list from a backtrace.
  ///
  /// @param frames  The frames to format.
  ///
  /// @result A `String` containing the formatted data.
  public func format(_ frames: [Backtrace.Frame]) -> String {
    var rows: [TableRow] = []

    var n = 0
    for frame in frames {
      let pc: String
      var attrs: [String] = []

      switch frame {
        case let .programCounter(address):
          pc = "\(hex(address))"
        case let .returnAddress(address):
          pc = "\(hex(address))"
          attrs.append("ra")
        case let .programCounterInAsync(address):
          pc = "\(hex(address))"
          attrs.append("ra")
        case let .returnAddressInAsync(address):
          pc = "\(hex(address))"
          attrs.append("ra")
          attrs.append("async")
        case let .asyncResumePoint(address):
          pc = "\(hex(address))"
          attrs.append("async")
        case .omittedFrames(_), .truncated:
          pc = "..."
      }

      var columns = [options._theme.frameIndex("\(n)"),
                     options._theme.programCounter(pc)]
      if options._showFrameAttributes {
        columns.append(attrs.map(
                          options._theme.frameAttribute
                       ).joined(separator: " "))
      }
      rows.append(.columns(columns))

      if case let .omittedFrames(count) = frame {
        n += count
      } else {
        n += 1
      }
    }

    return BacktraceFormatter.formatTable(rows, alignments: [.right])
  }

  /// Format a `Backtrace`
  ///
  /// @param backtrace  The `Backtrace` object to format.
  ///
  /// @result A `String` containing the formatted data.
  public func format(_ backtrace: Backtrace) -> String {
    return format(backtrace.frames)
  }

  /// Grab source lines for a symbolicated backtrace.
  ///
  /// Tries to open the file corresponding to the symbol; if successful,
  /// it will return a string containing the specified lines of context,
  /// with the point at which the program crashed highlighted.
  private func formattedSourceLines(from sourceLocation: SymbolicatedBacktrace.SourceLocation,
                                    indent theIndent: Int = 2) -> String? {
    guard let fp = fopen(sourceLocation.path, "rt") else { return nil }
    defer {
      fclose(fp)
    }

    let indent = String(repeating: " ", count: theIndent)
    var lines: [String] = []
    var line = 1
    let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 4096)
    var currentLine = ""

    let maxLine = sourceLocation.line + options._sourceContextLines
    let maxLineWidth = max("\(maxLine)".count, 4)

    let doLine = { sourceLine in
      if line >= sourceLocation.line - options._sourceContextLines
           && line <= sourceLocation.line + options._sourceContextLines {
        let untabified = untabify(sourceLine)
        let code = options._theme.code(untabified)
        let lineNumber = options._theme.lineNumber(pad("\(line)",
                                                       to: maxLineWidth,
                                                       aligned: .right))
        let theLine: String
        if line == sourceLocation.line {
          let highlightWidth = options._width - 2 * theIndent
          theLine = options._theme.crashedLine(pad("\(lineNumber)│ \(code) ",
                                                   to: highlightWidth))
        } else {
          theLine = "\(lineNumber)│ \(code)"
        }
        lines.append("\(indent)\(theLine)")

        if line == sourceLocation.line {
          // sourceLocation.column is an index in UTF-8 code units in
          // `untabified`.  We should point at the grapheme cluster that
          // contains that UTF-8 index.
          let adjustedColumn = max(sourceLocation.column, 1)
          let utf8Ndx = untabified.utf8.index(untabified.utf8.startIndex,
                                              offsetBy: adjustedColumn)

          // Adjust it to point at a grapheme cluster start
          let strNdx = untabified.index(before:
                                          untabified.index(after: utf8Ndx))

          // Work out the terminal width up to that point
          let terminalWidth = measure(untabified.prefix(upTo: strNdx))

          let pad = String(repeating: " ",
                           count: terminalWidth - 1)

          let marker = options._theme.crashLocation("▲")
          let blankForNumber = String(repeating: " ", count: maxLineWidth)

          lines.append("\(indent)\(blankForNumber)│ \(pad)\(marker)")
        }
      }
    }

    while feof(fp) == 0 && ferror(fp) == 0 {
      guard let result = fgets(buffer.baseAddress,
                               Int32(buffer.count), fp) else {
        break
      }

      let chunk = String(cString: result)
      currentLine += chunk
      if currentLine.hasSuffix("\n") {
        currentLine.removeLast()
        doLine(currentLine)
        currentLine = ""
        line += 1
      }
    }

    doLine(currentLine)

    return lines.joined(separator: "\n")
  }

  /// Format the frame list from a symbolicated backtrace.
  ///
  /// @param frames  The frames to format.
  ///
  /// @result A `String` containing the formatted data.
  public func format(_ frames: [SymbolicatedBacktrace.Frame]) -> String {
    var rows: [TableRow] = []
    var sourceLocationsShown = Set<SymbolicatedBacktrace.SourceLocation>()

    var n = 0
    for frame in frames {
      let pc: String
      var attrs: [String] = []

      switch frame.captured {
        case let .programCounter(address):
          pc = "\(hex(address))"
        case let .returnAddress(address):
          pc = "\(hex(address))"
          attrs.append("ra")
        case let .programCounterInAsync(address):
          pc = "\(hex(address))"
          attrs.append("ra")
        case let .returnAddressInAsync(address):
          pc = "\(hex(address))"
          attrs.append("ra")
          attrs.append("async")
        case let .asyncResumePoint(address):
          pc = "\(hex(address))"
          attrs.append("async")
        case .omittedFrames(_), .truncated:
          pc = ""
      }

      if frame.inlined {
        attrs.append("inlined")
      }

      var formattedSymbol: String? = nil
      var hasSourceLocation = false
      var isRuntimeFailure = false

      if let symbol = frame.symbol {
        let displayName = options._demangle ? symbol.name : symbol.rawName
        let themedName = options._theme.symbol(displayName)

        let offset: String
        if symbol.offset > 0 {
          offset = options._theme.offset(" + \(symbol.offset)")
        } else if symbol.offset < 0 {
          offset = options._theme.offset(" - \(-symbol.offset)")
        } else {
          offset = ""
        }

        let imageName: String
        if options._showImageNames {
          if symbol.imageIndex >= 0 {
            imageName = " in " + options._theme.imageName(symbol.imageName)
          } else {
            imageName = ""
          }
        } else {
          imageName = ""
        }

        isRuntimeFailure = symbol.isRuntimeFailure

        let location: String
        if var sourceLocation = symbol.sourceLocation {
          if options._sanitizePaths {
            sourceLocation.path = sanitizePath(sourceLocation.path)
          }
          location = " at " + options._theme.sourceLocation("\(sourceLocation)")
          hasSourceLocation = true
        } else {
          location = ""
        }

        formattedSymbol = "\(themedName)\(offset)\(imageName)\(location)"
      }

      if options._skipRuntimeFailures && isRuntimeFailure {
        continue
      }

      let location: String
      if !hasSourceLocation || options._showAddresses {
        let formattedPc = options._theme.programCounter(pc)
        if let formattedSymbol = formattedSymbol {
          location = "\(formattedPc) \(formattedSymbol)"
        } else {
          location = formattedPc
        }
      } else if let formattedSymbol = formattedSymbol {
        location = formattedSymbol
      } else {
        location = options._theme.programCounter(pc)
      }

      let frameIndex: String
      switch frame.captured {
        case .omittedFrames(_), .truncated:
          frameIndex = options._theme.frameIndex("...")
        default:
          frameIndex = options._theme.frameIndex("\(n)")
      }

      var columns = [frameIndex, location]
      if options._showFrameAttributes {
        columns.append(attrs.map(
                         options._theme.frameAttribute
                       ).joined(separator: " "))
      }
      rows.append(.columns(columns))

      if options._showSourceCode {
        if let symbol = frame.symbol,
           let sourceLocation = symbol.sourceLocation,
           !sourceLocationsShown.contains(sourceLocation) {
          if let lines = formattedSourceLines(from: sourceLocation) {
            rows.append(.raw(""))
            rows.append(.raw(lines))
            rows.append(.raw(""))
          }
          sourceLocationsShown.insert(sourceLocation)
        }
      }

      if case let .omittedFrames(count) = frame.captured {
        n += count
      } else {
        n += 1
      }
    }

    return BacktraceFormatter.formatTable(rows, alignments: [.right])
  }

  /// Format a `SymbolicatedBacktrace`
  ///
  /// @param backtrace  The `SymbolicatedBacktrace` object to format.
  ///
  /// @result A `String` containing the formatted data.
  public func format(_ backtrace: SymbolicatedBacktrace) -> String {
    return format(backtrace.frames)
  }

}
