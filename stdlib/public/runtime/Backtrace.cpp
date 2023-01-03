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
// Crash catching and backtracing support routines.
//
//===----------------------------------------------------------------------===//

#include "llvm/ADT/StringRef.h"

#include "swift/Runtime/Config.h"
#include "swift/Runtime/Backtrace.h"
#include "swift/Runtime/Debug.h"
#include "swift/Runtime/Paths.h"
#include "swift/Runtime/EnvironmentVariables.h"
#include "swift/Runtime/Win32.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif

#include <cstdlib>
#include <cstring>
#include <cerrno>

using namespace swift::runtime::backtrace;

namespace swift {
namespace runtime {
namespace backtrace {

SWIFT_RUNTIME_STDLIB_INTERNAL BacktraceSettings _swift_backtraceSettings = {
  Auto,

  // enabled
#if TARGET_OS_OSX
  TTY,
#elif defined(__linux__) || defined(_WIN32)
  On,
#else
  Off,
#endif

  // interactive
#if TARGET_OS_OSX || defined(__linux__) || defined(_WIN32)
  TTY,
#else
  Off,
#endif

  // color
  TTY,

  // timeout
  30,

  // level
  1,

  // swiftBacktracePath
  NULL,
};

}
}
}

namespace {

class BacktraceInitializer {
public:
  BacktraceInitializer();
};

SWIFT_ALLOWED_RUNTIME_GLOBAL_CTOR_BEGIN

BacktraceInitializer backtraceInitializer;

SWIFT_ALLOWED_RUNTIME_GLOBAL_CTOR_END

#define SWIFT_BACKTRACE_BUFFER_SIZE     8192

#if SWIFT_BACKTRACE_ON_CRASH_SUPPORTED

#if _WIN32
#pragma section(SWIFT_BACKTRACE_SECTION, read, write)
__declspec(allocate(SWIFT_BACKTRACE_SECTION)) WCHAR swiftBacktracePath[SWIFT_BACKTRACE_BUFFER_SIZE];
#elif defined(__linux__) || TARGET_OS_OSX
char swiftBacktracePath[SWIFT_BACKTRACE_BUFFER_SIZE] __attribute__((__section__(SWIFT_BACKTRACE_SECTION)));
#endif

#endif // SWIFT_BACKTRACE_ON_CRASH_SUPPORTED

void _swift_processBacktracingSetting(llvm::StringRef key, llvm::StringRef value);
void _swift_parseBacktracingSettings(const char *);

bool isStdoutATty()
{
#ifndef _WIN32
  return isatty(STDOUT_FILENO);
#else
  DWORD dwMode;
  return GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &dwMode);
#endif
}

bool isStdinATty()
{
#ifndef _WIN32
  return isatty(STDIN_FILENO);
#else
  DWORD dwMode;
  return GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &dwMode);
#endif
}

char *emptyEnv[] = { NULL };

} // namespace

BacktraceInitializer::BacktraceInitializer() {
  const char *backtracing = swift::runtime::environment::SWIFT_BACKTRACING();

  if (backtracing)
    _swift_parseBacktracingSettings(backtracing);

#if !SWIFT_BACKTRACE_ON_CRASH_SUPPORTED
  if (_swift_backtraceSettings.enabled) {
    swift::warning(0,
                   "backtrace-on-crash is not supported on this platform.");
    _swift_backtraceSettings.enabled = Off;
  }
#else
  if (_swift_backtraceSettings.enabled == TTY)
    _swift_backtraceSettings.enabled = isStdoutATty() ? On : Off;

  if (_swift_backtraceSettings.interactive == TTY)
    _swift_backtraceSettings.interactive = isStdinATty() ? On : Off;

  if (_swift_backtraceSettings.color == TTY)
    _swift_backtraceSettings.color = isStdoutATty() ? On : Off;

  if (_swift_backtraceSettings.enabled
      && !_swift_backtraceSettings.swiftBacktracePath) {
    _swift_backtraceSettings.swiftBacktracePath
      = swift_getAuxiliaryExecutablePath("swift-backtrace");

    if (!_swift_backtraceSettings.swiftBacktracePath) {
      swift::warning(0,
                     "unable to locate swift-backtrace; disabling backtracing.");
      _swift_backtraceSettings.enabled = Off;
    }
  }

  if (_swift_backtraceSettings.enabled) {
    // Copy the path to swift-backtrace into swiftBacktracePath, then write
    // protect it so that it can't be overwritten easily at runtime.  We do
    // this to avoid creating a massive security hole that would allow an
    // attacker to overwrite the path and then cause a crash to get us to
    // execute an arbitrary file.

#if _WIN32
    switch (_swift_backtraceSettings.algorithm) {
    case DWARF:
      swift::warning(0,
                     "DWARF unwinding is not supported on this platform.");
    case Auto:
      _swift_backtraceSettings.algorithm = SEH;
      break;
    default:
      break;
    }

    int len = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                    _swift_backtraceSettings.swiftBacktracePath, -1,
                                    swiftBacktracePath,
                                    SWIFT_BACKTRACE_BUFFER_SIZE);
    if (!len) {
      swift::warning(0,
                     "unable to convert path to swift-backtrace: %08lx; "
                     "disabling backtracing.",
                     ::GetLastError());
      _swift_backtraceSettings.enabled = Off;
    } else if (!VirtualProtect(swiftBacktracePath,
                               sizeof(swiftBacktracePath),
                               PAGE_READONLY,
                               NULL)) {
      swift::warning(0,
                     "unable to protect path to swift-backtrace: %08lx; "
                     "disabling backtracing.",
                     ::GetLastError());
      _swift_backtraceSettings.enabled = Off;
    }
#else
    switch (_swift_backtraceSettings.algorithm) {
    case SEH:
      swift::warning(0,
                     "SEH unwinding is not supported on this platform.");
    case Auto:
      _swift_backtraceSettings.algorithm = DWARF;
      break;
    default:
      break;
    }

    size_t len = strlen(_swift_backtraceSettings.swiftBacktracePath);
    if (len > SWIFT_BACKTRACE_BUFFER_SIZE - 1) {
      swift::warning(0,
                     "path to swift-backtrace is too long; "
                     "disabling backtracing.");
      _swift_backtraceSettings.enabled = Off;
    } else {
      memcpy(swiftBacktracePath,
             _swift_backtraceSettings.swiftBacktracePath,
             len + 1);

      if (mprotect(swiftBacktracePath,
                   SWIFT_BACKTRACE_BUFFER_SIZE,
                   PROT_READ) < 0) {
        swift::warning(0,
                       "unable to protect path to swift-backtrace: %d; "
                       "disabling backtracing.",
                       errno);
        _swift_backtraceSettings.enabled = Off;
      }
    }
#endif
  }

  if (_swift_backtraceSettings.enabled) {
    _swift_installCrashHandler();
  }
#endif
}

namespace {

OnOffTty
parseOnOffTty(llvm::StringRef value)
{
  if (value.equals_insensitive("on")
      || value.equals_insensitive("true")
      || value.equals_insensitive("yes"))
    return On;
  if (value.equals_insensitive("tty")
      || value.equals_insensitive("auto"))
    return TTY;
  return Off;
}

bool
parseBoolean(llvm::StringRef value)
{
  return (value.equals_insensitive("on")
          || value.equals_insensitive("true")
          || value.equals_insensitive("yes"));
}

void
_swift_processBacktracingSetting(llvm::StringRef key,
                                 llvm::StringRef value)

{
  if (key.equals_insensitive("enable")) {
    _swift_backtraceSettings.enabled = parseOnOffTty(value);
  } else if (key.equals_insensitive("symbolicate")) {
    _swift_backtraceSettings.symbolicate = parseBoolean(value);
  } else if (key.equals_insensitive("interactive")) {
    _swift_backtraceSettings.interactive = parseOnOffTty(value);
  } else if (key.equals_insensitive("color")) {
    _swift_backtraceSettings.color = parseOnOffTty(value);
  } else if (key.equals_insensitive("timeout")) {
    int count;
    llvm::StringRef valueCopy = value;

    if (value.equals_insensitive("none")) {
      _swift_backtraceSettings.timeout = 0;
    } else if (valueCopy.consumeInteger(0, count)) {
      llvm::StringRef unit = valueCopy.trim();

      if (unit.empty()
          || unit.equals_insensitive("s")
          || unit.equals_insensitive("seconds"))
        _swift_backtraceSettings.timeout = count;
      else if (unit.equals_insensitive("m")
               || unit.equals_insensitive("minutes"))
        _swift_backtraceSettings.timeout = count * 60;
      else if (unit.equals_insensitive("h")
               || unit.equals_insensitive("hours"))
        _swift_backtraceSettings.timeout = count * 3600;

      if (_swift_backtraceSettings.timeout < 0) {
        swift::warning(0,
                       "bad backtracing timeout %ds\n",
                       _swift_backtraceSettings.timeout);
        _swift_backtraceSettings.timeout = 0;
      }
    } else {
      swift::warning(0,
                     "bad backtracing timeout '%.*s'\n",
                     static_cast<int>(value.size()), value.data());
    }
  } else if (key.equals_insensitive("unwind")) {
    if (value.equals_insensitive("auto"))
      _swift_backtraceSettings.algorithm = Auto;
    else if (value.equals_insensitive("fast"))
      _swift_backtraceSettings.algorithm = Fast;
    else if (value.equals_insensitive("DWARF"))
      _swift_backtraceSettings.algorithm = DWARF;
    else if (value.equals_insensitive("SEH"))
      _swift_backtraceSettings.algorithm = SEH;
    else {
      swift::warning(0,
                     "unknown backtracing algorithm '%.*s'\n",
                     static_cast<int>(value.size()), value.data());
    }
  } else if (key.equals_insensitive("level")) {
    if (!value.getAsInteger(0, _swift_backtraceSettings.verbosity)) {
      swift::warning(0,
                     "bad backtracing level '%.*s'\n",
                     static_cast<int>(value.size()), value.data());
    }
  } else if (key.equals_insensitive("swift-backtrace")) {
    size_t len = value.size();
    char *path = (char *)std::malloc(len + 1);
    std::copy(value.begin(), value.end(), path);
    path[len] = 0;

    std::free(const_cast<char *>(_swift_backtraceSettings.swiftBacktracePath));
    _swift_backtraceSettings.swiftBacktracePath = path;
  }
}

void
_swift_parseBacktracingSettings(const char *settings)
{
  const char *ptr = settings;
  const char *key = ptr;
  const char *keyEnd;
  const char *value;
  const char *valueEnd;
  enum {
    ScanningKey,
    ScanningValue
  } state = ScanningKey;
  int ch;

  while ((ch = *ptr++)) {
    switch (state) {
    case ScanningKey:
      if (ch == '=') {
        keyEnd = ptr - 1;
        value = ptr;
        state = ScanningValue;
        continue;
      }
      break;
    case ScanningValue:
      if (ch == ',') {
        valueEnd = ptr - 1;
        key = ptr;
        state = ScanningKey;

        _swift_processBacktracingSetting(llvm::StringRef(key, keyEnd - key),
                                         llvm::StringRef(value,
                                                         valueEnd - value));
        continue;
      }
      break;
    }
  }

  if (state == ScanningValue) {
    valueEnd = ptr - 1;
    _swift_processBacktracingSetting(llvm::StringRef(key, keyEnd - key),
                                     llvm::StringRef(value,
                                                     valueEnd - value));
  }
}

} // namespace

namespace swift {
namespace runtime {
namespace backtrace {

SWIFT_RUNTIME_STDLIB_INTERNAL bool
_swift_spawnBacktracer(const ArgChar **argv)
{
#if TARGET_OS_OSX
  pid_t child;
  int ret = posix_spawn(&child, swiftBacktracePath, NULL, NULL,
                        argv, emptyEnv);
  if (ret < 0)
    return false;

  int wstatus;

  do {
    ret = waitpid(child, &wstatus, 0);
  } while (ret < 0 && errno == EINTR);

  if (WIFEXITED(wstatus))
    return WEXITSTATUS(wstatus);

  return false;

  // ###TODO: Linux
  // ###TODO: Windows
#else
  return false;
#endif
}

} // namespace backtrace
} // namespace runtime
} // namespace swift
