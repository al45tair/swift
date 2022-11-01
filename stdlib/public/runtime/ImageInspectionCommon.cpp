//===--- ImageInspectionCommon.cpp - Image inspection routines --*- C++ -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
///
/// \file
///
/// This file unifies common ELF and COFF image inspection routines
///
//===----------------------------------------------------------------------===//

#ifndef SWIFT_RUNTIME_IMAGEINSPECTIONCOMMON_H
#define SWIFT_RUNTIME_IMAGEINSPECTIONCOMMON_H

#if !defined(__MACH__)

#include "swift/shims/Visibility.h"
#include "swift/ABI/MetadataSections.h"
#include "ImageInspection.h"
#include "swift/Basic/Lazy.h"
#include "swift/Runtime/Concurrent.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>

namespace swift {

static Lazy<ConcurrentReadableArray<const swift::MetadataSections *>> registered;

}

/// Find the image base address given the sections pointer
#ifndef NDEBUG
SWIFT_RUNTIME_EXPORT
#else
static
#endif
const void *swift_getMetadataSectionBaseAddress(const swift::MetadataSections *sections) {
  swift::SymbolInfo symbolInfo;
  if (lookupSymbol(sections, &symbolInfo) && symbolInfo.baseAddress)
    return symbolInfo.baseAddress;
  return nullptr;
}

static inline ptrdiff_t
computeSectionLength(const void *start, const void *end) {
  return (reinterpret_cast<const char *>(end)
          - reinterpret_cast<const char *>(start));
}

SWIFT_RUNTIME_EXPORT
void swift_addNewDSOImage(const void *image,
                          const swift::MetadataSections *sections) {
#if 0
  // If one of the registration functions below starts needing the base
  // address, this call will need to be enabled.
  if (!image)
    image = swift_getMetadataSectionBaseAddress(sections);
#endif

#define SWIFT_METADATA_CALLBACK(name,CamelCase)                         \
  do {                                                                  \
    const void *start = sections->swift5_##name.start.get();            \
    const void *end = sections->swift5_##name.end.get();                \
    auto length = computeSectionLength(start, end);                     \
    if (length) {                                                       \
      swift::addImage##CamelCase##BlockCallback(image, start, length);  \
    }                                                                   \
  } while(0)

#define SWIFT_METADATA_CALLBACK2(name,name2,CamelCase)                  \
  do {                                                                  \
    const void *start = sections->swift5_##name.start.get();            \
    const void *end = sections->swift5_##name.end.get();                \
    auto length = computeSectionLength(start, end);                     \
    if (length) {                                                       \
      const void *start2 = sections->swift5_##name2.start.get();        \
      const void *end2 = sections->swift5_##name2.end.get();            \
      auto length2 = computeSectionLength(start2, end2);                \
      swift::addImage##CamelCase##BlockCallback(image, start, length,   \
                                                start2, length2);       \
    }                                                                   \
  } while(0)

  SWIFT_METADATA_CALLBACK(protocols, Protocols);
  SWIFT_METADATA_CALLBACK(protocol_conformances, ProtocolConformance);
  SWIFT_METADATA_CALLBACK(type_metadata, TypeMetadataRecord);
  SWIFT_METADATA_CALLBACK2(replace, replac2, DynamicReplacement);
  SWIFT_METADATA_CALLBACK(accessible_functions, AccessibleFunctions);

  // Register this section for future enumeration by clients. This should occur
  // after this function has done all other relevant work to avoid a race
  // condition when someone calls swift_enumerateAllMetadataSections() on
  // another thread.
  swift::registered->push_back(sections);
}

SWIFT_RUNTIME_EXPORT
void swift_enumerateAllMetadataSections(
  bool (* body)(const swift::MetadataSections *sections, void *context),
  void *context
) {
  auto snapshot = swift::registered->snapshot();
  for (const swift::MetadataSections *sections : snapshot) {
    // Yield the pointer and (if the callback returns false) break the loop.
    if (!(* body)(sections, context)) {
      return;
    }
  }
}

void swift::initializeProtocolLookup() {
}

void swift::initializeProtocolConformanceLookup() {
}

void swift::initializeTypeMetadataRecordLookup() {
}

void swift::initializeDynamicReplacementLookup() {
}

void swift::initializeAccessibleFunctionsLookup() {
}

#ifndef NDEBUG

SWIFT_RUNTIME_EXPORT
const swift::MetadataSections *swift_getMetadataSection(size_t index) {
  const swift::MetadataSections *result = nullptr;

  auto snapshot = swift::registered->snapshot();
  if (index < snapshot.count()) {
    result = snapshot[index];
  }

  return result;
}

SWIFT_RUNTIME_EXPORT
const char *
swift_getMetadataSectionName(const swift::MetadataSections *section) {
  swift::SymbolInfo info;
  if (lookupSymbol(section, &info)) {
    if (info.fileName) {
      return info.fileName;
    }
  }
  return "";
}

SWIFT_RUNTIME_EXPORT
size_t swift_getMetadataSectionCount() {
  auto snapshot = swift::registered->snapshot();
  return snapshot.count();
}

#endif // NDEBUG

#endif // !defined(__MACH__)

#endif // SWIFT_RUNTIME_IMAGEINSPECTIONCOMMON_H
