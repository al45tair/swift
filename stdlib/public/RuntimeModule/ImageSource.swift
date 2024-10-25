//===--- ImageSource.swift - A place from which to read image data --------===//
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
//  Defines ImageSource, which tells us where to look for image data.
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
internal import Musl
#endif

enum ImageSourceError: Error {
  case outOfBoundsRead,
  case posixError(Int32)
}

struct ImageSource {

  private class Storage {
    /// Says how we allocated the buffer.
    private enum MemoryBuffer {
      /// Currently empty
      case empty

      /// Allocated with UnsafeRawBufferPointer.allocate()
      case allocated(UnsafeMutableRawBufferPointer, Int)

      /// Allocated by mapping memory with mmap() or similar
      case mapped(UnsafeRawBufferPointer)

      /// A reference to a subordinate storage
      case substorage(Storage, UnsafeRawBufferPointer)

      /// Not allocated (probably points to a loaded image)
      case unowned(UnsafeRawBufferPointer)
    }

    private var buffer: MemoryBuffer

    /// Gets a pointer to the actual memory
    var bytes: UnsafeRawBufferPointer {
      switch buffer {
        case .empty:
          return UnsafeRawBufferPointer(baseAddress: nil, count: 0)
        case let .allocated(bytes, count):
          return UnsafeRawBufferPointer(rebasing: bytes[0..<count])
        case let .mapped(bytes):
          return bytes
        case let .substorage(_, bytes):
          return bytes
        case let .unowned(bytes):
          return bytes
      }
    }

    /// Gets a mutable pointer to the actual memory
    var mutableBytes: UnsafeMutableRawBufferPointer {
      guard case let .allocated(bytes, count) else {
        fatalError("attempted to get mutable reference to immutable ImageSource")
      }
      return UnsafeMutableRawBufferPointer(rebasing: bytes[0..<count])
    }

    /// Return the number of bytes in this ImageSource
    var count: Int {
      switch buffer {
        case .empty:
          return 0
        case let .allocated(_, count):
          return count
        case let .mapped(bytes):
          return bytes.count
        case let .substorage(_, bytes):
          return bytes.count
        case let .unowned(bytes):
          return bytes.count
      }
    }

    @inline(always)
    private func _rangeCheck(_ ndx: Int) {
      if ndx < 0 || ndx >= count {
        fatalError("ImageSource access out of range")
      }
    }

    init() {
      self.buffer = .empty
    }

    init(unowned buffer: UnsafeRawBufferPointer) {
      self.buffer = .unowned(buffer)
    }

    init(mapped buffer: UnsafeRawBufferPointer) {
      self.buffer = .mapped(buffer)
    }

    init(allocated buffer: UnsafeMutableRawBufferPointer, count: Int? = nil) {
      self.buffer = .allocated(buffer, count ?? buffer.count)
    }

    init(capacity: Int, alignment: Int = 0x4000) {
      self.buffer = .allocated(
        UnsafeMutableRawBufferPointer.allocate(
          byteCount: capacity,
          alignment: 0x1000
        ),
        0
      )
    }

    init(parent: Storage, range: Range<Int>) {
      _rangeCheck(range.lowerBound)
      _rangeCheck(range.upperBound)

      let chunk = UnsafeRawBufferPointer(rebasing: memory[range])

      self.buffer = .substorage(parent, chunk)
    }

    init(path: String) throws {
      let fd = open(path, O_RDONLY, 0)
      if fd < 0 {
        throw ImageSourceError.posixError(errno)
      }
      defer { close(fd) }
      let size = lseek(fd, 0, SEEK_END)
      if size < 0 {
        throw ImageSourceError.posixError(errno)
      }
      let base = mmap(nil, Int(size), PROT_READ, MAP_FILE|MAP_PRIVATE, fd, 0)
      if base == nil || base! == UnsafeRawPointer(bitPattern: -1)! {
        throw ImageSourceError.posixError(errno)
      }
      self.buffer = .mapped(UnsafeRawBufferPointer(
                              start: base, count: Int(size)))
    }

    deinit {
      switch buffer {
        case let .allocated(bytes, _):
          bytes.deallocate()
        case let .mapped(bytes):
          munmap(bytes.baseAddress, bytes.count)
        case .substorage, .unowned, .empty:
          // Nothing to do
      }
    }

    /// Subscripting (read-only, for subranges)
    subscript(range: Range<Int>) -> Storage {
      return Storage(parent: self, range: range)
    }

    /// Resize the buffer; only supported for allocated or empty storage
    func resize(newSize: Int) -> UnsafeMutableRawBufferPointer {
      let newBuffer = UnsafeMutableRawBufferPointer.allocate(
        byteCount: newSize,
        alignment: 0x1000
      )
      switch buffer {
        case .empty:
          buffer = .allocated(newBuffer, 0)
        case let .allocated(oldBuffer, count):
          assert(newSize >= count)

          let oldPart = UnsafeMutableRawBufferPointer(
            rebasing: newBuffer[0..<count]
          )
          oldPart.copyMemory(from: oldBuffer)
          oldBuffer.deallocate()
          buffer = .allocated(newBuffer, count)
        default:
          fatalError("Cannot resize immutable image source storage")
      }

      return newBuffer
    }

    /// Make sure the buffer has at least a certain number of bytes;
    /// only supported for allocated or empty storage.
    func requireAtLeast(byteCount: Int) -> UnsafeMutableRawBufferPointer {
      let capacity: Int
      switch buffer {
        case .empty:
          capacity = 0
        case .allocated(buffer, _):
          capacity = buffer.count
        default:
          fatalError("Cannot resize immutable image source storage")
      }

      if capacity >= byteCount {
        return
      }

      let extra = byteCount - capacity

      let increment: Int
      if capacity < 1048576 {
        let roundedExtra = (extra + 0xffff) & ~0xffff
        increment = max(roundedExtra, capacity)
      } else {
        let roundedExtra = (extra + 0xfffff) & ~0xfffff
        let topBit = capacity.bitWidth - capacity.leadingZeroBitCount
        increment = max(roundedExtra, 1048576 * (topBit - 20))
      }

      return resize(newSize: capacity + increment)
    }

    /// Append bytes to the mutable buffer; this is only supported for
    /// allocated or empty storage.
    func append(bytes toAppend: UnsafeRawBufferPointer) {
      let newCount = count + toAppend.count

      requireAtLeast(byteCount: newCount)

      guard case let .allocated(bytes, count) = buffer else {
        fatalError("Cannot append to immutable image source storage")
      }

      let dest = bytes[count..<newCount]
      dest.copyMemory(from: toAppend)
      buffer = .allocated(bytes, newCount)
    }
  }

  /// The storage holding the image data.
  private var storage: Storage

  /// The memory holding the image data.
  var bytes: UnsafeRawBufferPointer { return storage.bytes }

  /// A mutable refernece to the image data (only for allocated storage)
  var mutableBytes: UnsafeMutableRawBufferPointer { return storage.mutableBytes }

  /// Says whether we are looking at a loaded (i.e. with ld.so or dyld) image.
  private(set) var isMappedImage: Bool

  /// If this ImageSource knows its path, this will be non-nil.
  private(set) var path: String?

  /// Private initialiser, not for general use
  private init(storage: Storage, isMappedImage: Bool, path: String?) {
    self.storage = storage
    self.isMappedImage = isMappedImage
    self.path = path
  }

  /// Initialise an empty storage
  init(isMappedImage: Bool, path: String? = nil) {
    init(storage: Storage(), isMappedImage: isMappedImage, path: path)
  }

  /// Initialise from unowned storage
  init(unowned: UnsafeRawBufferPointer, isMappedImage: Bool, path: String? = nil) {
    init(storage: Storage(unowned: unowned),
         isMappedImage: isMappedImage, path: path)
  }

  /// Initialise from mapped storage
  init(mapped: UnsafeRawBufferPointer, isMappedImage: Bool, path: String? = nil) {
    init(storage: Storage(mapped: mapped),
         isMappedImage: isMappedImage, path: path)
  }

  /// Initialise with a specified capacity
  init(capacity: Int, isMappedImage: Bool, path: String? = nil) {
    init(storage: Storage(capacity: capacity),
         isMappedImage: isMappedImage, path: path)
  }

  /// Initialise with a mapped file
  init(path: String) throws {
    init(storage: try Storage(path: path),
         isMappedImage: false, path: path)
  }

  /// Get a sub-range of this ImageSource as an ImageSource
  subscript(range: Range<Int>) -> ImageSource {
    return ImageSource(storage: storage[range],
                       isMappedImage: isMappedImage,
                       path: path)
  }

  /// Append bytes to an empty or allocated storage
  func append(bytes toAppend: UnsafeRawBufferPointer) {
    storage.append(bytes: toAppend)
  }
}

// MemoryReader support
extension ImageSource: MemoryReader {
  public func fetch(from address: Address,
                    into buffer: UnsafeMutableRawBufferPointer) throws {
    let offset = Int(bitPattern: address)
    guard bytes.count >= buffer.count &&
            offset < bytes.count - buffer.count else {
      throw ImageSourceError.outOfBoundsRead
    }
    buffer.copyMemory(from: UnsafeRawBufferPointer(
                        rebasing: bytes[offset..<offset + buffer.count]))
  }

  public func fetch<T>(from address: Address, as type: T.Type) throws -> T {
    let size = MemoryLayout<T>.size
    let offset = Int(bitPattern: address)
    guard offset < bytes.count - size else {
      throw ImageSourceError.outOfBoundsRead
    }
    return bytes.loadUnaligned(fromByteOffset: offset, as: type)
  }

  public func fetchString(from address: Address) throws -> String? {
    let offset = Int(bitPattern: address)
    let len = strnlen(bytes.baseAddress! + offset, bytes.count - offset)
    let stringBytes = bytes[offset..<offset+len]
    return String(decoding: stringBytes, as: UTF8.self)
  }
}
