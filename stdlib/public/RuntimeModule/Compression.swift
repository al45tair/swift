//===--- Compression.swift - Data compression for ELF images --------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// Defines the compressed image sources, which are used to access compressed
// data from ELF images.
//
// There are three different compression formats we might have to interact
// with, namely zlib (deflate), zstd and LZMA.  We don't implement the
// decompression algorithms here, but rather we will try to use zlib,
// zstd and liblzma respectively.
//
// We support two different modes; one is where the compression libraries
// have been statically linked with us, in which case we can just call them;
// the other is where we will try to load them with `dlopen()`.  We do this
// so as to avoid a hard dependency on them in the runtime.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Swift

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
internal import Darwin
#elseif os(Windows)
internal import ucrt
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif
internal import BacktracingImpl.CompressionLibs
internal import BacktracingImpl.ImageFormats.Elf

enum CompressedImageSourceError: Error {
  case unboundedImageSource
  case outOfRangeFetch(UInt64, Int)
  case badCompressedData
  case unsupportedFormat
  case libraryNotFound(String)
  case outputOverrun
}

// .. CompressedStream .........................................................

protocol CompressedStream {
  typealias InputSource = () throws -> UnsafeRawBufferPointer
  typealias OutputSink = (_ used: UInt, _ done: Bool) throws
    -> UnsafeMutableRawBufferPointer?

  func decompress(input: InputSource, output: OutputSink) throws -> UInt
}

// .. Compression library bindings .............................................

private var lzmaHandle = dlopen("liblzma.so.5", RTLD_LAZY)
private var zlibHandle = dlopen("libz.so.1", RTLD_LAZY)
private var zstdHandle = dlopen("libzstd.so.1", RTLD_LAZY)

private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
  guard let handle = handle, let result = dlsym(handle, name) else {
    return nil
  }
  return unsafeBitCast(result, to: T.self)
}

private enum Sym {
  static let lzma_stream_decoder: (
    @convention(c) (UnsafeMutablePointer<lzma_stream>,
                    UInt64, UInt32) -> lzma_ret)?
    = symbol(lzmaHandle, "lzma_stream_decoder")

  static let lzma_code: (@convention(c) (UnsafeMutablePointer<lzma_stream>,
                                         lzma_action) -> lzma_ret)?
    = symbol(lzmaHandle, "lzma_code")

  static let lzma_end: (@convention(c) (UnsafeMutablePointer<lzma_stream>) -> ())?
    = symbol(lzmaHandle, "lzma_end")

  static let inflateInit_: (@convention(c) (z_streamp,
                                            UnsafePointer<CChar>, CInt) -> CInt)?
    = symbol(zlibHandle, "inflateInit_")

  static func inflateInit(_ stream: z_streamp) -> CInt {
    return inflateInit_!(stream, ZLIB_VERSION, CInt(MemoryLayout<z_stream>.size))
  }

  static let inflate: (@convention(c) (z_streamp, CInt) -> CInt)?
    = symbol(zlibHandle, "inflate")

  static let inflateEnd: (@convention(c) (z_streamp) -> CInt)?
    = symbol(zlibHandle, "inflateEnd")

  static let ZSTD_createDStream: (
    @convention(c) () -> UnsafeMutableRawPointer?)?
    = symbol(zstdHandle, "ZSTD_createDStream")

  static let ZSTD_freeDStream: (
    @convention(c) (UnsafeMutableRawPointer) -> UInt)?
    = symbol(zstdHandle, "ZSTD_freeDStream")

  static let ZSTD_decompressStream: (
    @convention(c) (UnsafeMutableRawPointer,
                    UnsafeMutablePointer<ZSTD_outBuffer>,
                    UnsafeMutablePointer<ZSTD_inBuffer>) -> UInt)?
    = symbol(zstdHandle, "ZSTD_decompressStream")

  static let ZSTD_isError: (@convention(c) (UInt) -> UInt)?
    = symbol(zstdHandle, "ZSTD_isError")
}

// .. zlib (deflate) ...........................................................

enum ZLibError: Error {
  case decodeError(CInt)
}

struct ZLibStream: CompressedStream {
  init() {}

  func decompress(input: InputSource, output: OutputSink) throws -> UInt {

    if zlibHandle == nil {
      throw CompressedImageSourceError.libraryNotFound("libz")
    }

    var stream = zlib_stream_init()

    let ret = Sym.inflateInit(&stream)
    if ret != Z_OK {
      throw ZLibError.decodeError(ret)
    }
    defer {
      _ = Sym.inflateEnd!(&stream)
    }

    var outputBufferSize = UInt(0)
    while true {
      if stream.avail_in == 0 {
        let buffer = try input()

        // Not really mutable; this is just an issue with z_const
        stream.next_in = UnsafeMutablePointer(mutating: buffer.baseAddress)
        stream.avail_in = CUnsignedInt(buffer.count)
      }

      if stream.avail_out == 0 {
        guard let buffer = try output(outputBufferSize, false) else {
          throw CompressedImageSourceError.outputOverrun
        }

        stream.next_out = buffer.baseAddress
        stream.avail_out = CUnsignedInt(buffer.count)
        outputBufferSize = UInt(buffer.count)
      }

      let ret = Sym.inflate!(&stream, Z_NO_FLUSH)

      if ret == Z_STREAM_END {
        _ = try output(outputBufferSize - UInt(stream.avail_out), true)
        return stream.total_out
      }

      if ret != Z_OK {
        throw ZLibError.decodeError(ret)
      }
    }
  }
}

// .. zstd .....................................................................

enum ZStdError: Error {
  case unableToCreateStream
  case decodeError(UInt)
}

struct ZStdStream: CompressedStream {
  init() {}

  func decompress(input: InputSource, output: OutputSink) throws -> UInt {

    if zstdHandle == nil {
      throw CompressedImageSourceError.libraryNotFound("libzstd")
    }

    guard let stream = Sym.ZSTD_createDStream!() else {
      throw ZStdError.unableToCreateStream
    }
    defer {
      _ = Sym.ZSTD_freeDStream!(stream)
    }

    var inBuffer = ZSTD_inBuffer(src: nil, size: 0, pos: 0)
    var outBuffer = ZSTD_outBuffer(dst: nil, size: 0, pos: 0)
    var totalOutput = UInt(0)

    while true {
      if inBuffer.size == inBuffer.pos {
        let buffer = try input()

        inBuffer.src = UnsafeRawPointer(buffer.baseAddress)
        inBuffer.size = buffer.count
        inBuffer.pos = 0
      }

      if outBuffer.size == outBuffer.pos {
        let byteCount = UInt(outBuffer.pos)

        totalOutput += byteCount

        guard let buffer = try output(byteCount, false) else {
          throw CompressedImageSourceError.outputOverrun
        }

        outBuffer.dst = UnsafeMutableRawPointer(buffer.baseAddress)
        outBuffer.size = buffer.count
        outBuffer.pos = 0
      }

      let ret = Sym.ZSTD_decompressStream!(stream, &outBuffer, &inBuffer)

      if ret == 0 {
        _ = try output(UInt(outBuffer.pos), true)
        return totalOutput
      }

      if Sym.ZSTD_isError!(ret) != 0 {
        throw ZStdError.decodeError(ret)
      }
    }
  }
}


// .. LZMA .....................................................................

enum LZMAError: Error {
  case decodeError(lzma_ret)
}

struct LZMAStream: CompressedStream {
  private var memlimit: UInt64
  private var flags: UInt32

  init(memlimit: UInt64 = ~UInt64(0), flags: UInt32 = 0) {
    self.memlimit = memlimit
    self.flags = flags
  }

  func decompress(input: InputSource, output: OutputSink) throws -> UInt {

    if lzmaHandle == nil {
      throw CompressedImageSourceError.libraryNotFound("liblzma")
    }

    var stream = lzma_stream_init()

    let ret = Sym.lzma_stream_decoder!(&stream, memlimit, flags)
    if ret != LZMA_OK {
      throw LZMAError.decodeError(ret)
    }
    defer {
      Sym.lzma_end!(&stream)
    }

    var outputBufferSize = UInt(0)
    while true {
      if stream.avail_in == 0 {
        let buffer = try input()
        stream.next_in = buffer.baseAddress
        stream.avail_in = buffer.count
      }

      if stream.avail_out == 0 {
        guard let buffer = try output(outputBufferSize, false) else {
          throw CompressedImageSourceError.outputOverrun
        }

        stream.next_out = buffer.baseAddress
        stream.avail_out = buffer.count
        outputBufferSize = UInt(buffer.count)
      }

      let ret = Sym.lzma_code!(&stream, LZMA_RUN)

      if ret == LZMA_STREAM_END {
        _ = try output(outputBufferSize - UInt(stream.avail_out), true)
        return UInt(stream.total_out)
      }

      if ret != LZMA_OK {
        throw LZMAError.decodeError(ret)
      }
    }
  }
}

// .. Image Sources ............................................................

fileprivate func decompress<S: CompressedStream>(
  stream: S,
  source: ImageSource,
  offset: Int,
  output: ImageSource
) {
  _ = try stream.decompress(
    input: {
      () throws -> UnsafeRawBufferPointer in

      return UnsafeRawBufferPointer(rebasing: source.bytes[offset...])
    },
    output: {
      (used: UInt, done: Bool) throws -> UnsafeMutableRawBufferPointer? in

      if used == 0 {
        return output.mutableBytes
      } else {
        return nil
      }
    }
  )
}

fileprivate func decompressChunked<S: CompressedStream>(
  stream: S,
  source: ImageSource,
  offset: Int,
  output: ImageSource
) {
  let bufSize = 65536
  let outputBuffer = UnsafeMutableRawBufferPointer.allocate(capacity: bufSize)
  defer {
    outputBuffer.deallocate()
  }

  _ = try stream.decompress(
    input: {
      () throws -> UnsafeRawBufferPointer in

      return UnsafeRawBufferPointer(rebasing: source.bytes[offset...])
    },
    output: {
      (used: UInt, done: Bool) throws -> UnsafeMutableRawBufferPointer? in

      output.append(
        bytes: UnsafeRawBufferPointer(rebasing: outputBuffer[..<Int(used)])
      )
      if !done {
        return outputBuffer
      } else {
        return nil
      }
    }
  )
}

fileprivate func decompress<S: CompressedStream>(
  stream: S,
  source: ImageSource,
  dataBounds: I.Bounds,
  uncompressedSize: UInt? = nil
) throws -> ImageSource {

  var pos = dataBounds.base
  var remaining = dataBounds.size

  let bufSize = 65536

  if let uncompressedSize = uncompressedSize {
    // If we know the uncompressed size, we can decompress directly into the
    // array.

    let inputBuffer
      = UnsafeMutableRawBufferPointer.allocate(capacity: bufSize)
    defer {
      inputBuffer.deallocate()
    }

    var output = ImageSource(capacity: Int(uncompressedSize),
                             isMappedImage: false)

    _ = try stream.decompress(
      input: {
        () throws -> UnsafeRawBufferPointer in

        let chunkSize = min(Int(remaining), inputBuffer.count)
        let slice = inputBuffer[0..<chunkSize]
        let buffer = UnsafeMutableBufferPointer(rebasing: slice)

        try source.fetch(from: pos, into: buffer)

        pos += I.Address(chunkSize)
        remaining -= I.Size(chunkSize)

        return UnsafeBufferPointer(buffer)
      },
      output: {
        (used: UInt, done: Bool) throws -> UnsafeMutableRawBufferPointer? in

        if used == 0 {
          return outputBuffer.mutableBytes
        } else {
          return nil
        }
      }
    )

    return output
  } else {
    // Otherwise, we decompress in chunks and append them to the array.

    let buffer
      = UnsafeMutableRawBufferPointer.allocate(capacity: 2 * bufSize)
    defer {
      buffer.deallocate()
    }

    let inputBuffer = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<bufSize])
    let outputBuffer = UnsafeMutableRawBufferPointer(rebasing: buffer[bufSize...])

    var output = ImageSource(isMappedImage: false)

    _ = try stream.decompress(
      input: { () throws -> UnsafeRawBufferPointer in

        let chunkSize = min(Int(remaining), inputBuffer.count)
        let slice = inputBuffer[0..<chunkSize]
        let buffer = UnsafeMutableBufferPointer(rebasing: slice)

        try source.fetch(from: pos, into: buffer)

        pos += I.Address(chunkSize)
        remaining -= I.Size(chunkSize)

        return UnsafeBufferPointer(buffer)
      },
      output: {
        (used: UInt, done: Bool) throws -> UnsafeMutableRawBufferPointer? in

        output.append(
          bytes: UnsafeRawBufferPointer(rebasing: outputBuffer[..<Int(used)])
        )
        if !done {
          return outputBuffer
        } else {
          return nil
        }
      }
    )

    return output
  }
}

extension ImageSource {
  @_specialize(kind: full, where Traits == Elf32Traits)
  @_specialize(kind: full, where Traits == Elf64Traits)
  init<Traits: ElfTraits>(elfCompressedSource source: ImageSource) throws {
    if source.size < MemoryLayout<Traits.Chdr>.size {
      throw CompressedImageSourceError.badCompressedData
    }

    let rawChdr = try source.fetch(from: 0, as: Traits.Chdr.self)
    let chdr: Traits.Chdr
    switch rawChdr.ch_type {
      case .ELFCOMPRESS_ZLIB.byteSwapped, .ELFCOMPRESS_ZSTD.byteSwapped:
        chdr = rawChdr.byteSwapped
      default:
        chdr = rawChdr
    }

    let uncompressedSize = UInt(chdr.ch_size)

    init(capacity: Int(uncompressedSize), isMappedImage: false, path: nil)

    switch chdr.ch_type {
      case .ELFCOMPRESS_ZLIB:
        try decompress(ZlibStream(),
                       source: source, offset: MemoryLayout<Elf32_Chdr>.stride,
                       output: self)
      case .ELFCOMPRESS_ZSTD:
        try decompress(ZstdStream(),
                       source: source, offset: MemoryLayout<Elf32_Chdr>.stride,
                       output: self)
      default:
        throw CompressedImageSourceError.unsupportedFormat
    }
  }

  init(gnuCompressedImageSource source: ImageSource,
       byteSwap: Bool) throws {
    if source.size < 12 {
      throw CompressedImageSourceError.badCompressedData
    }

    let magic = try source.fetch(from: 0, as: UInt32.self)
    let rawUncompressedSize = try source.fetch(from: 4, as: UInt64.self)
    let uncompressedSize: UInt64
    switch magic {
      case 0x42494c5a: // BILZ
        uncompressedSize = rawUncompressedSize.byteSwapped
      case 0x5a4c4942: // ZLIB
        uncompressedSize = rawUncompressedSize
      default:
        throw CompressedImageSourceError.badCompressedData
    }

    init(capacity: Int(uncompressedSize), isMappedImage: false, path: nil)

    try decompress(ZlibStream(),
                   source: source, offset: 12,
                   output: self)
  }

  init(lzmaCompressedImageSource source: ImageSource) throws {
    init(isMappedImage: false, path: nil)

    try decompressChunked(LZMAStream(),
                          source: source, offset: 0,
                          output: self)
  }
}

#endif // os(Linux)
