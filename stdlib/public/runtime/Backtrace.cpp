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
#include <spawn.h>
#include <unistd.h>
#endif

#include <cstdlib>
#include <cstring>
#include <cerrno>

#define DEBUG_BACKTRACING_PASS_THROUGH_DYLD_LIBRARY_PATH 1
#define DEBUG_BACKTRACING_SETTINGS                       1

#if DEBUG_BACKTRACING_PASS_THROUGH_DYLD_LIBRARY_PATH
#warning ***WARNING*** THIS SETTING IS INSECURE.  IT SHOULD NOT BE ENABLED IN PRODUCTION
#endif

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

  // symbolicate
  true,
  
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

// We need swiftBacktracePath to be aligned on a page boundary
#if defined(__APPLE__) && defined(__arm64__)
#define SWIFT_BACKTRACE_ALIGN 16384
#else
#define SWIFT_BACKTRACE_ALIGN 4096
#endif

#if _WIN32
#pragma section(SWIFT_BACKTRACE_SECTION, read, write)
__declspec(allocate(SWIFT_BACKTRACE_SECTION)) WCHAR swiftBacktracePath[SWIFT_BACKTRACE_BUFFER_SIZE];
#elif defined(__linux__) || TARGET_OS_OSX
char swiftBacktracePath[SWIFT_BACKTRACE_BUFFER_SIZE] __attribute__((section(SWIFT_BACKTRACE_SECTION), aligned(SWIFT_BACKTRACE_ALIGN)));
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

const char * const emptyEnv[] = { NULL };

#if DEBUG_BACKTRACING_SETTINGS
const char *algorithmToString(UnwindAlgorithm algorithm) {
  switch (algorithm) {
  case Auto: return "Auto";
  case Fast: return "Fast";
  case DWARF: return "DWARF";
  case SEH: return "SEH";
  }
}

const char *onOffTtyToString(OnOffTty oot) {
  switch (oot) {
  case On: return "On";
  case Off: return "Off";
  case TTY: return "TTY";
  }
}

const char *boolToString(bool b) {
  return b ? "true" : "false";
}
#endif

} // namespace

BacktraceInitializer::BacktraceInitializer() {
  const char *backtracing = swift::runtime::environment::SWIFT_BACKTRACING();

  if (backtracing)
    _swift_parseBacktracingSettings(backtracing);

#if !SWIFT_BACKTRACE_ON_CRASH_SUPPORTED
  if (_swift_backtraceSettings.enabled) {
    swift::warning(0,
                   "backtrace-on-crash is not supported on this platform.\n");
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
                     "unable to locate swift-backtrace; "
                     "disabling backtracing.\n");
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
                     "DWARF unwinding is not supported on this platform.\n");
      SWIFT_FALLTHROUGH;
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
                     "disabling backtracing.\n",
                     ::GetLastError());
      _swift_backtraceSettings.enabled = Off;
    } else if (!VirtualProtect(swiftBacktracePath,
                               sizeof(swiftBacktracePath),
                               PAGE_READONLY,
                               NULL)) {
      swift::warning(0,
                     "unable to protect path to swift-backtrace: %08lx; "
                     "disabling backtracing.\n",
                     ::GetLastError());
      _swift_backtraceSettings.enabled = Off;
    }
#else
    switch (_swift_backtraceSettings.algorithm) {
    case SEH:
      swift::warning(0,
                     "SEH unwinding is not supported on this platform.\n");
      SWIFT_FALLTHROUGH;
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
                     "disabling backtracing.\n");
      _swift_backtraceSettings.enabled = Off;
    } else {
      memcpy(swiftBacktracePath,
             _swift_backtraceSettings.swiftBacktracePath,
             len + 1);

      if (mprotect(swiftBacktracePath,
                   SWIFT_BACKTRACE_BUFFER_SIZE,
                   PROT_READ) < 0) {
        swift::warning(0,
                       "unable to protect path to swift-backtrace at %p: %d; "
                       "disabling backtracing.\n",
                       swiftBacktracePath,
                       errno);
        _swift_backtraceSettings.enabled = Off;
      }
    }
#endif
  }

  if (_swift_backtraceSettings.enabled) {
    ErrorCode err = _swift_installCrashHandler();
    if (err != 0) {
      swift::warning(0,
                     "crash handler installation failed; "
                     "disabling backtracing.\n");
    }
  }
#endif

#if DEBUG_BACKTRACING_SETTINGS
  printf("\nBACKTRACING SETTINGS\n"
         "\n"
         "algorithm: %s\n"
         "enabled: %s\n"
         "symbolicate: %s\n"
         "interactive: %s\n"
         "color: %s\n"
         "timeout: %u\n"
         "level: %u\n"
         "swiftBacktracePath: %s\n\n",
         algorithmToString(_swift_backtraceSettings.algorithm),
         onOffTtyToString(_swift_backtraceSettings.enabled),
         boolToString(_swift_backtraceSettings.symbolicate),
         onOffTtyToString(_swift_backtraceSettings.interactive),
         onOffTtyToString(_swift_backtraceSettings.color),
         _swift_backtraceSettings.timeout,
         _swift_backtraceSettings.level,
         swiftBacktracePath);
#endif
}

namespace {

OnOffTty
parseOnOffTty(llvm::StringRef value)
{
  if (value.equals_insensitive("on")
      || value.equals_insensitive("true")
      || value.equals_insensitive("yes")
      || value.equals_insensitive("y")
      || value.equals_insensitive("t")
      || value.equals_insensitive("1"))
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
          || value.equals_insensitive("yes")
          || value.equals_insensitive("y")
          || value.equals_insensitive("t")
          || value.equals_insensitive("1"));
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
    if (!value.getAsInteger(0, _swift_backtraceSettings.level)) {
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
  } else {
    swift::warning(0,
                   "unknown backtracing setting '%.*s'\n",
                   static_cast<int>(key.size()), key.data());
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

        _swift_processBacktracingSetting(llvm::StringRef(key, keyEnd - key),
                                         llvm::StringRef(value,
                                                         valueEnd - value));

        key = ptr;
        state = ScanningKey;
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

// N.B. THIS FUNCTION MUST BE SAFE TO USE FROM A CRASH HANDLER.  On Linux
// and macOS, that means it must be async-signal-safe.  On Windows, there
// isn't an equivalent notion but a similar restriction applies.
SWIFT_RUNTIME_STDLIB_INTERNAL bool
_swift_spawnBacktracer(const ArgChar * const *argv)
{
#if TARGET_OS_OSX
  pid_t child;
  const char * const *envp = emptyEnv;

  #if DEBUG_BACKTRACING_PASS_THROUGH_DYLD_LIBRARY_PATH
  const char *dyldEnv[] = {
    getenv("DYLD_LIBRARY_PATH"),
    NULL
  };

  envp = dyldEnv;
  #endif

  // SUSv3 says argv and envp are "completely constant" and that the reason
  // posix_spawn() et al use char * const * is for compatibility.

  int ret = posix_spawn(&child, swiftBacktracePath, NULL, NULL,
                        const_cast<char * const *>(argv),
                        const_cast<char * const *>(envp));
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
