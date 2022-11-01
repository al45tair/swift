//===--- TargetMetadataSections.h -----------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// This file contains the declaration of the TargetMetadataSectionsRange and
// TargetMetadataSections struct, which represent, respectively,  information about
// an image's section, and an image's metadata information (which is composed
// of multiple section information).
//
// These structures are used on non-Mach-O platforms to locate Swift metadata
// in an image.
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_ABI_METADATASECTIONS_H
#define SWIFT_ABI_METADATASECTIONS_H

#include <cstdint>

namespace swift {

struct MetadataSectionTraits32 {
  using Version = uint32_t;
  using Offset = int32_t;
};

struct MetadataSectionTraits64 {
  using Version = uint64_t;
  using Offset = int64_t;
};

/// Either an absolute or a relative pointer, depending on platform.
///
/// On Win32, we cannot easily construct relative pointers (relocations
/// cannot refer to items in other sections), we there we have to use
/// absolute pointers instead.
///
/// Note that this may get used in cases where the bitness of the inspecting
/// process doesn't match the bitness of the data being read.
template <typename Traits>
class TargetMetadataSectionPointer {
public:
  using Offset = typename Traits::Offset;

private:
  Offset RelativeOrAbsolute;

  TargetMetadataSectionPointer() = delete;
  TargetMetadataSectionPointer(TargetMetadataSectionPointer &&) = delete;
  TargetMetadataSectionPointer(const TargetMetadataSectionPointer &) = delete;
  TargetMetadataSectionPointer &operator=(TargetMetadataSectionPointer &&) = delete;
  TargetMetadataSectionPointer &operator=(const TargetMetadataSectionPointer &) = delete;

  Offset applyRelativeOffset(Offset UnresolvedOffset) const {
    Offset base = reinterpret_cast<Offset>(this);
    return base + UnresolvedOffset;
  }

public:
  // Windows needs this, for now
  explicit TargetMetadataSectionPointer(const void *AbsolutePointer)
    : RelativeOrAbsolute(reinterpret_cast<Offset>(AbsolutePointer))
  {}

  bool isRelative() const {
    return RelativeOrAbsolute & 1;
  }

  Offset getUnresolvedOffset() const {
    return RelativeOrAbsolute & ~Offset(1);
  }

  Offset getResolvedAddress() const {
    if (isRelative())
      return applyRelativeOffset(getUnresolvedOffset());
    else
      return reinterpret_cast<Offset>(RelativeOrAbsolute);
  }

  const void *get() const & {
    return reinterpret_cast<const void *>(getResolvedAddress());
  }

  operator const void* () const {
    return get();
  }

  const void *operator->() const {
    return get();
  }
};

/// Specifies the address range corresponding to a section
template <typename Traits>
struct TargetMetadataSectionRange {
  TargetMetadataSectionPointer<Traits> start;
  TargetMetadataSectionPointer<Traits> end;
};

/// Under ELF, notes owned by Swift are identified by this string
#define SWIFT_NT_SWIFT_NAME                    "Swift"

/// Under ELF, the TargetMetadataSections structure is held in a note with this type
#define SWIFT_NT_SWIFT_METADATA                1

/// The version number must be incremented if the structure below changes;
/// this includes when you add a section to the list.
#define SWIFT_CURRENT_SECTION_METADATA_VERSION 3

/// Identifies the address space ranges for the Swift metadata required by the
/// Swift runtime.
///
/// \warning If you change the size of this structure by adding fields, it is an
///   ABI-breaking change on platforms that use it. Make sure to increment
///   \c SWIFT_CURRENT_SECTION_METADATA_VERSION if you do.
template <typename Traits>
struct TargetMetadataSections {
  using Version = typename Traits::Version;
  using Offset = typename Traits::Offset;
  using SectionRange = TargetMetadataSectionRange<Traits>;

  Version version;

  SectionRange swift5_protocols;
  SectionRange swift5_protocol_conformances;
  SectionRange swift5_type_metadata;
  SectionRange swift5_typeref;
  SectionRange swift5_reflstr;
  SectionRange swift5_fieldmd;
  SectionRange swift5_assocty;
  SectionRange swift5_replace;
  SectionRange swift5_replac2;
  SectionRange swift5_builtin;
  SectionRange swift5_capture;
  SectionRange swift5_mpenum;
  SectionRange swift5_accessible_functions;
};

#if __LP64__ || _WIN64
using MetadataSectionTraits = MetadataSectionTraits64;
#else
using MetadataSectionTraits = MetadataSectionTraits32;
#endif

using MetadataSectionPointer
  = TargetMetadataSectionPointer<MetadataSectionTraits>;
using MetadataSectionRange = TargetMetadataSectionRange<MetadataSectionTraits>;
using MetadataSections = TargetMetadataSections<MetadataSectionTraits>;

} // namespace swift

#endif // SWIFT_ABI_METADATASECTIONS_H
