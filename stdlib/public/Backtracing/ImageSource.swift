//===--- ImageSource.swift - A place from which to read image data --------===//
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
// Defines ImageSource, which is a protocol that can be implemented to
// provide an image reader with a way to read data from a file, a buffer
// in memory, or wherever we might wish to read an image from.
//
//===----------------------------------------------------------------------===//

import Swift

internal protocol ImageSource : MemoryReader {
  /// Says whether we are looking at a loaded image in memory or not.
  /// The layout in memory may differ from the on-disk layout; in particular,
  /// some information may not be available when the image is mapped into
  /// memory (an example is ELF section headers).
  var isMappedImage: Bool { get }

  /// If this ImageSource knows its path, this will be non-nil.
  var path: String? { get }

  /// Holds the bounds of an ImageSource
  struct Bounds {
    var base: Address
    var size: Size
  }

  /// If this ImageSource knows its bounds, this will be non-nil.
  var bounds: Bounds? { get }
}

enum SubImageSourceError: Error {
  case outOfRangeFetch(UInt64, Int)
}

internal struct SubImageSource<S: ImageSource>: ImageSource {
  typealias Address = S.Address
  typealias Size = S.Size

  var parent: S
  var baseAddress: S.Address
  var length: S.Size

  var bounds: Bounds? {
    return Bounds(base: 0, size: length)
  }

  public init(parent: S, baseAddress: S.Address, length: S.Size) {
    self.parent = parent
    self.baseAddress = baseAddress
    self.length = length
  }

  public var isMappedImage: Bool {
    return parent.isMappedImage
  }

  public func fetch<T>(from addr: Address,
                       into buffer: UnsafeMutableBufferPointer<T>) throws {
    let toFetch = buffer.count * MemoryLayout<T>.stride
    if addr < 0 || addr > length {
      throw SubImageSourceError.outOfRangeFetch(UInt64(addr), toFetch)
    }
    if S.Address(length) - addr < toFetch {
      throw SubImageSourceError.outOfRangeFetch(UInt64(addr), toFetch)
    }

    return try parent.fetch(from: baseAddress + addr, into: buffer)
  }
}
