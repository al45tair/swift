//===--- Backtrace.cpp - Swift crash catching and backtracing support ---- ===//
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
// Definitions relating to backtracing.
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_RUNTIME_BACKTRACE_H
#define SWIFT_RUNTIME_BACKTRACE_H

#include "swift/Runtime/Config.h"

#include "swift/shims/Visibility.h"
#include "swift/shims/_SwiftBacktracing.h"

#include <inttypes.h>

#ifdef __cplusplus
namespace swift {
namespace runtime {
namespace backtrace {
#endif

#ifdef _WIN32
typedef wchar_t ArgChar;
typedef DWORD ErrorCode;
#else
typedef char ArgChar;
typedef int ErrorCode;
#endif

SWIFT_RUNTIME_STDLIB_INTERNAL ErrorCode _swift_installCrashHandler();

SWIFT_RUNTIME_STDLIB_INTERNAL bool _swift_spawnBacktracer(const ArgChar * const *argv);

enum class UnwindAlgorithm {
  Auto = 0,
  Fast = 1,
  Precise = 2
};

enum class OnOffTty {
  Off = 0,
  On = 1,
  TTY = 2
};

enum class Preset {
  Auto = 0,
  Friendly = 0,
  Medium = 1,
  Full = 2
};

struct BacktraceSettings {
  UnwindAlgorithm  algorithm;
  OnOffTty         enabled;
  bool             symbolicate;
  OnOffTty         interactive;
  OnOffTty         color;
  unsigned         timeout;
  Preset           preset;
  const char      *swiftBacktracePath;
};

SWIFT_RUNTIME_STDLIB_INTERNAL BacktraceSettings _swift_backtraceSettings;

SWIFT_RUNTIME_STDLIB_SPI SWIFT_CC(swift) bool _swift_isThunkFunction(const char *mangledName);

#ifdef __cplusplus
} // namespace backtrace
} // namespace runtime
} // namespace swift
#endif

#endif // SWIFT_RUNTIME_BACKTRACE_H
