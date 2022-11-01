//===--- SwiftRT-COFF.cpp -------------------------------------------------===//
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

#include "ImageInspectionCommon.h"

#include "swift/ABI/MetadataSections.h"

#include <cstdint>
#include <new>

extern "C" const char __ImageBase[];

#define PASTE_EXPANDED(a,b) a##b
#define PASTE(a,b) PASTE_EXPANDED(a,b)

#define STRING_EXPANDED(string) #string
#define STRING(string) STRING_EXPANDED(string)

#define C_LABEL(name) PASTE(__USER_LABEL_PREFIX__,name)

#define _PRAGMA(pragma) _Pragma(#pragma)
#define PRAGMA(pragma) _PRAGMA(pragma)

#define START_NAME(sect) STRING(.##sect##$A)
#define STOP_NAME(sect) STRING(.##sect##$C)

#define DECLARE_SWIFT_SECTION(name)             \
  PRAGMA(section(START_NAME(name), long, read)) \
  __declspec(allocate(START_NAME(#name)))       \
  __declspec(align(1))                          \
  static uintptr_t __start_##name = 0;          \
                                                \
  PRAGMA(section(STOP_NAME(name), long, read))  \
  __declspec(allocate(STOP_NAME(name)))         \
  __declspec(align(1))                          \
  static uintptr_t __stop_##name = 0;

#define SWIFT5_SECTIONS                                 \
  SWIFT5_SECTION(sw5prt, swift5_protocols)              \
  SWIFT5_SECTION(sw5prtc, swift5_protocol_conformances) \
  SWIFT5_SECTION(sw5tymd, swift5_type_metadata)         \
  SWIFT5_SECTION(sw5tyrf, swift5_typeref)               \
  SWIFT5_SECTION(sw5rfst, swift5_reflstr)               \
  SWIFT5_SECTION(sw5flmd, swift5_fieldmd)               \
  SWIFT5_SECTION(sw5asty, swift5_assocty)               \
  SWIFT5_SECTION(sw5repl, swift5_replace)               \
  SWIFT5_SECTION(sw5reps, swift5_replac2)               \
  SWIFT5_SECTION(sw5bltn, swift5_builtin)               \
  SWIFT5_SECTION(sw5cptr, swift5_capture)               \
  SWIFT5_SECTION(sw5mpen, swift5_mpenum)                \
  SWIFT5_SECTION(sw5acfn, swift5_accessible_functions)

extern "C" {
#undef SWIFT5_SECTION
#define SWIFT5_SECTION(s,l) DECLARE_SWIFT_SECTION(s)
  SWIFT5_SECTIONS
}

#define SWIFT_SECTION_RANGE(name,var) \
  { MetadataSectionPointer(&__start_##name), \
    MetadataSectionPointer(&__stop_##name) }

static constexpr swift::MetadataSections sections = {
  SWIFT_CURRENT_SECTION_METADATA_VERSION,

#undef SWIFT5_SECTION
#define SWIFT5_SECTION(name,var) SWIFT_SECTION_RANGE(name,var),
  SWIFT5_SECTIONS
};

static void swift_image_constructor() {
  swift_addNewDSOImage(__ImageBase, &sections);
}

#pragma section(".CRT$XCIS", long, read)

__declspec(allocate(".CRT$XCIS"))
extern "C" void (*pSwiftImageConstructor)(void) = &swift_image_constructor;
#pragma comment(linker, "/include:" STRING(C_LABEL(pSwiftImageConstructor)))

