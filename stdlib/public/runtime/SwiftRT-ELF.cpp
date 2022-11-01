//===--- SwiftRT-ELF.cpp --------------------------------------------------===//
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

#undef STR
#undef _STR

#define _STR(x) #x
#define STR(x) _STR(x)

// Some things differ depending on whether this is 32 or 64-bit
#if __LP64__
__asm__("                       \n\
        .macro AlignNote        \n\
        .align 8                \n\
        .endm                   \n\
                                \n\
        .macro Offset value     \n\
        .quad \\value           \n\
        .endm                   \n\
                                \n\
        .macro Version value    \n\
        .quad \\value           \n\
        .endm                   \n\
");
#else
__asm__("                       \n\
        .macro AlignNote        \n\
        .align 4                \n\
        .endm                   \n\
                                \n\
        .macro Offset value     \n\
        .long \\value           \n\
        .endm                   \n\
                                \n\
        .macro Version value    \n\
        .long \\value           \n\
        .endm                   \n\
");
#endif

// Generate the ELF note
__asm__("                                                               \n\
        // Declare a section and import its start and end symbols       \n\
        .macro DeclareSection name                                      \n\
        .section \\name,\"a\"                                           \n\
        .global __start_\\name                                          \n\
        .global __end_\\name                                            \n\
        .endm                                                           \n\
                                                                        \n\
        // Emit a relative pointer                                      \n\
        .macro RelativePtr symbol                                       \n\
        Offset \\symbol - . + 1                                         \n\
        .endm                                                           \n\
                                                                        \n\
        // Emit a section descriptor                                    \n\
        .macro EmitSectionDescriptor name                               \n\
        RelativePtr __start_\\name                                      \n\
        RelativePtr __end_\\name                                        \n\
        .endm                                                           \n\
                                                                        \n\
        // Run a specified macro for each of the sections               \n\
        .macro ForEachSection macro                                     \n\
        \\macro swift5_protocols                                        \n\
        \\macro swift5_protocol_conformances                            \n\
        \\macro swift5_type_metadata                                    \n\
        \\macro swift5_typeref                                          \n\
        \\macro swift5_reflstr                                          \n\
        \\macro swift5_fieldmd                                          \n\
        \\macro swift5_assocty                                          \n\
        \\macro swift5_replace                                          \n\
        \\macro swift5_replac2                                          \n\
        \\macro swift5_builtin                                          \n\
        \\macro swift5_capture                                          \n\
        \\macro swift5_mpenum                                           \n\
        \\macro swift5_accessible_functions                             \n\
        .endm                                                           \n\
                                                                        \n\
        // Create empty sections to ensure that the start/stop symbols  \n\
        // are synthesized by the linker.                               \n\
        ForEachSection DeclareSection                                   \n\
                                                                        \n\
        // Now write an ELF note that points at all of the above        \n\
        .section \".note.swift5_metadata\",\"a\"                        \n\
        AlignNote                                                       \n\
        .long 1f - 0f   // n_namesz                                     \n\
        .long 3f - 2f   // n_descsz                                     \n\
        .long " STR(SWIFT_NT_SWIFT_METADATA) "                          \n\
                                                                        \n\
0:      .asciz \"" SWIFT_NT_SWIFT_NAME "\"                              \n\
1:                                                                      \n\
        AlignNote                                                       \n\
                                                                        \n\
        .hidden __swift5_metadata                                       \n\
        .global __swift5_metadata                                       \n\
__swift5_metadata:                                                      \n\
                                                                        \n\
2:      Version " STR(SWIFT_CURRENT_SECTION_METADATA_VERSION) "         \n\
                                                                        \n\
        ForEachSection EmitSectionDescriptor                            \n\
                                                                        \n\
3:                                                                      \n\
");

extern const swift::MetadataSections __swift5_metadata;

// On image load, notify the Swift runtime
__attribute__((__constructor__))
static void swift_image_constructor() {
  swift_addNewDSOImage(nullptr, &__swift5_metadata);
}
