//===--- CrashHandlerMacOS.cpp - Swift crash handler for macOS ----------- ===//
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
// The macOS crash handler implementation.
//
// We use signal handling rather than trying to use Mach exceptions here,
// because the latter would entail running a separate Mach server thread, and
// creates a much greater risk of interfering with the system wide Crash
// Reporter, which is a no-no.
//
//===----------------------------------------------------------------------===//

#ifdef __APPLE__

#include <TargetConditionals.h>

#if TARGET_OS_OSX

#include <mach/mach.h>
#include <mach/task.h>
#include <mach/thread_act.h>

#include <sys/mman.h>
#include <sys/ucontext.h>
#include <sys/wait.h>

#include <os/lock.h>

#include <errno.h>
#include <signal.h>
#include <spawn.h>

#include "swift/Runtime/Backtrace.h"

#ifndef lengthof
#define lengthof(x)     (sizeof(x) / sizeof(x[0]))
#endif

using namespace swift::runtime::backtrace;

namespace {

void handle_fatal_signal(int signum, siginfo_t *pinfo, void *uctx);
bool run_backtracer(void);

swift::CrashInfo crashInfo;

const int signalsToHandle[] = {
  SIGQUIT,
  SIGABRT,
  SIGBUS,
  SIGFPE,
  SIGILL,
  SIGSEGV,
  SIGTRAP
};

} // namespace

namespace swift {
namespace runtime {
namespace backtrace {

SWIFT_RUNTIME_STDLIB_INTERNAL int
_swift_installCrashHandler()
{
  stack_t ss;

  // Install an alternate signal handling stack
  ss.ss_flags = 0;
  ss.ss_size = SIGSTKSZ;
  ss.ss_sp = mmap(0, ss.ss_size, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (ss.ss_sp == MAP_FAILED)
    return errno;

  // Now register signal handlers
  struct sigaction sa;

  sigfillset(&sa.sa_mask);
  for (unsigned n = 0; n < lengthof(signalsToHandle); ++n) {
    sigdelset(&sa.sa_mask, signalsToHandle[n]);
  }

  sa.sa_handler = NULL;

  for (unsigned n = 0; n < lengthof(signalsToHandle); ++n) {
    sa.sa_flags = SA_ONSTACK | SA_SIGINFO | SA_NODEFER;
    sa.sa_sigaction = handle_fatal_signal;

    if (sigaction(signalsToHandle[n], &sa, NULL) < 0)
      return errno;
  }

  return 0;
}

} // namespace backtrace
} // namespace runtime
} // namespace swift

namespace {

void
handle_fatal_signal(int signum,
                    siginfo_t *pinfo,
                    void *uctx)
{
  int old_err = errno;

  // Remove our signal handlers; crashes should kill us here
  for (unsigned n = 0; n < lengthof(signalsToHandle); ++n)
    signal(signalsToHandle[n], SIG_DFL);

  // Get our thread identifier
  thread_identifier_info_data_t ident_info;
  mach_msg_type_number_t ident_size = THREAD_IDENTIFIER_INFO_COUNT;

  int ret = thread_info(mach_thread_self(),
                        THREAD_IDENTIFIER_INFO,
                        (int *)&ident_info,
                        &ident_size);
  if (ret != KERN_SUCCESS)
    return;

  // Fill in crash info
  crashInfo.crashing_thread = ident_info.thread_id;
  crashInfo.signal = signum;
  crashInfo.fault_address = (uint64_t)pinfo->si_addr;
  crashInfo.mctx = (uint64_t)(((ucontext_t *)uctx)->uc_mcontext);

  /* Start the backtracer; this will suspend the process, so there's no need
     to try to suspend other threads from here. */
  run_backtracer();

  // Restore errno and exit (to crash)
  errno = old_err;
}

char addr_buf[18];
char timeout_buf[22];
char level_buf[22];
const char *backtracer_argv[] = {
  "swift-backtrace",            // 0
  "--unwind",                   // 1
  "DWARF",                      // 2
  "--symbolicate",              // 3
  "true",                       // 4
  "--interactive",              // 5
  "true",                       // 6
  "--color",                    // 7
  "true",                       // 8
  "--timeout",                  // 9
  timeout_buf,                  // 10
  "--level",                    // 11
  level_buf,                    // 12
  "--crashinfo",                // 13
  addr_buf,                     // 14
  NULL
};

// We can't call sprintf() here because we're in a signal handler,
// so we need to be async-signal-safe.
void
format_address(uintptr_t addr, char buffer[18])
{
  char *ptr = buffer + 18;
  *--ptr = '\0';
  while (ptr > buffer) {
    char digit = '0' + (addr & 0xf);
    if (digit > '9')
      digit += 'a' - '0' - 10;
    *--ptr = digit;
    addr >>= 4;
    if (!addr)
      break;
  }

  // Left-justify in the buffer
  if (ptr > buffer) {
    char *pt2 = buffer;
    while (*ptr)
      *pt2++ = *ptr++;
    *pt2++ = '\0';
  }
}
void
format_address(const void *ptr, char buffer[18])
{
  format_address(reinterpret_cast<uintptr_t>(ptr), buffer);
}

// See above; we can't use sprintf() here.
void
format_unsigned(unsigned u, char buffer[22])
{
  char *ptr = buffer + 22;
  *--ptr = '\0';
  while (ptr > buffer) {
    char digit = '0' + (u % 10);
    *--ptr = digit;
    u /= 10;
    if (!u)
      break;
  }

  // Left-justify in the buffer
  if (ptr > buffer) {
    char *pt2 = buffer;
    while (*ptr)
      *pt2++ = *ptr++;
    *pt2++ = '\0';
  }
}

bool
run_backtracer()
{
  // Forward our task port to the backtracer
  mach_port_t ports[] = {
    mach_task_self(),
  };

  mach_ports_register(mach_task_self(), ports, 1);

  // Set-up the backtracer's command line arguments
  switch (_swift_backtraceSettings.algorithm) {
  case Fast:
    backtracer_argv[2] = "fast";
    break;
  default:
    backtracer_argv[2] = "DWARF";
    break;
  }

  // (The TTY option has already been handled at this point, so these are
  //  all either "On" or "Off".)
  backtracer_argv[4] = _swift_backtraceSettings.symbolicate ? "true" : "false";
  backtracer_argv[6] = _swift_backtraceSettings.interactive ? "true" : "false";
  backtracer_argv[8] = _swift_backtraceSettings.color ? "true" : "false";

  format_unsigned(_swift_backtraceSettings.timeout, timeout_buf);
  format_unsigned(_swift_backtraceSettings.level, level_buf);
  format_address(&crashInfo, addr_buf);

  // Actually execute it
  return _swift_spawnBacktracer(backtracer_argv);
}

} // namespace

#endif // TARGET_OS_OSX

#endif // __APPLE__

