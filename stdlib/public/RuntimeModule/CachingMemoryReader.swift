//===--- CachingMemoryReader.swift ----------------------------*- swift -*-===//
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
//  Wraps a MemoryReader in a layer that caches memory pages.
//
//===----------------------------------------------------------------------===//

import Swift

// The size of the pages in the page cache (must be a power of 2)
fileprivate let pageSize = 4096

fileprivate let pageMask = pageSize - 1

// The largest chunk we will try to cache data for
fileprivate let maxCachedSize = pageSize * 8

@_spi(MemoryReaders)
#if os(Linux)
@_specialize(exported: true, kind: full, where T == MemserverMemoryReader)
#endif
@_specialize(exported: true, kind: full, where T == RemoteMemoryReader)
@_specialize(exported: true, kind: full, where T == LocalMemoryReader)
public class CachingMemoryReader<T: MemoryReader>: MemoryReader {
  private var reader: T
  private var cache: [Address:UnsafeRawBufferPointer]

  public init(for reader: T) {
    self.reader = reader
    self.cache = [:]
  }

  deinit {
    for (_, page) in cache {
      page.deallocate()
    }
  }

  private func getPage(at address: Address) throws -> UnsafeRawBufferPointer {
    precondition((address & Address(pageMask)) == 0)

    if let page = cache[address] {
      return page
    }

    let page = UnsafeMutableRawBufferPointer.allocate(byteCount: pageSize,
                                                      alignment: pageSize)
    try reader.fetch(from: address, into: page)

    let result = UnsafeRawBufferPointer(page)

    cache[address] = result

    return result
  }

  public func fetch(from address: Address,
                    into buffer: UnsafeMutableRawBufferPointer) throws {
    guard buffer.count <= maxCachedSize else {
      try reader.fetch(from: address, into: buffer)
      return
    }

    var pageAddress = address & ~Address(pageMask)
    var done = 0
    var offset = Int(address - pageAddress)
    var remaining = buffer.count

    while remaining > 0 {
      let page = try getPage(at: pageAddress)
      let maxBytes = pageSize - offset
      let chunk = min(remaining, maxBytes)

      buffer[done..<done+chunk].copyBytes(from: page[offset..<offset+chunk])

      offset = 0
      done += chunk
      remaining -= chunk
      pageAddress += Address(pageSize)
    }
  }
}
