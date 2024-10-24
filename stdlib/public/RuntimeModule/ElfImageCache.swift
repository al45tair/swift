//===--- ElfImageCache.swift - ELF support for Swift ----------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// Provides a per-thread Elf image cache that improves efficiency when
// taking multiple backtraces by avoiding loading ELF images multiple times.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
internal import Darwin
#elseif os(Windows)
internal import ucrt
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

/// Provides a per-thread image cache for ELF image processing.  This means
/// if you take multiple backtraces from a thread, you won't load the same
/// image multiple times.
final class ElfImageCache {
  var elf32: [String: Elf32Image] = [:]
  var elf64: [String: Elf64Image] = [:]

  func purge() {
    elf32Cache = [:]
    elf64Cache = [:]
  }

  private static var key: pthread_key_t = {
    var theKey = pthread_key_t()
    let err = pthread_key_create(
      &theKey,
      { rawPtr in
        let ptr = Unmanaged<ElfImageCache>.fromOpaque(rawPtr)
        ptr.release()
      }
    )
    if err != 0 {
      return nil
    }
    return theKey
  }()

  static var threadLocal: ElfImageCache {
    guard let rawPtr = pthread_getspecific(key!) else {
      let cache = Unmanaged<ElfImageCache>.passRetained(ElfImageCache())
      pthread_setspecific(key!, cache.toOpaque())
      return cache.takeUnretainedValue()
    }
    let cache = Unmanaged<ElfImageCache>.fromOpaque(rawPtr)
    return cache.takeUnretainedValue()
  }
}
