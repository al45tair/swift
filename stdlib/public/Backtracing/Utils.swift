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
// Utility functions that are used in the backtracing library.
//
//===----------------------------------------------------------------------===//

internal func hex<T: FixedWidthInteger>(_ value: T) -> String {
  let digits = String(value, radix: 16)
  let padTo = value.bitWidth / 4
  let padding = digits.count >= padTo ? "" : String(repeating: "0",
                                                    count: padTo - digits.count)

  return "0x\(padding)\(digits)"
}
