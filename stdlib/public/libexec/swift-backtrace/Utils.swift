//===--- Utils.swift - Utility functions ----------------------------------===//
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
// Utility functions that are used in the swift-backtrace program.
//
//===----------------------------------------------------------------------===//

import Swift

internal func hex<T: FixedWidthInteger>(_ value: T,
                                        withPrefix: Bool = true) -> String {
  let digits = String(value, radix: 16)
  let padTo = value.bitWidth / 4
  let padding = digits.count >= padTo ? "" : String(repeating: "0",
                                                    count: padTo - digits.count)
  let prefix = withPrefix ? "0x" : ""

  return "\(prefix)\(padding)\(digits)"
}

internal func hex(_ bytes: [UInt8]) -> String {
  return bytes.map{ hex($0, withPrefix: false) }.joined(separator: "")
}

internal func parseUInt64<S: StringProtocol>(_ s: S) -> UInt64? {
  if s.hasPrefix("0x") {
    return UInt64(s.dropFirst(2), radix: 16)
  } else if s.hasPrefix("0b") {
    return UInt64(s.dropFirst(2), radix: 2)
  } else if s.hasPrefix("0o") {
    return UInt64(s.dropFirst(2), radix: 8)
  } else {
    return UInt64(s, radix: 10)
  }
}
