# swift-backtrace

`swift-backtrace` is a tool that is used by the Swift runtime to generate
backtraces when Swift programs crash.  It is not something that is intended for
end users to run directly - indeed, it has unusual and platform specific
requirements for the environment in which it is launched.

### Building

swift-backtrace can be built using
[swift-package-manager](https://github.com/apple/swift-package-manager).

### Launch mechanism

`swift-backtrace` is launched by a Swift program when it detects that it has
crashed.  The crashing process will then wait for `swift-backtrace` to complete;
if `swift-backtrace` terminates or crashes, the crashing process will proceed
to crash as it would have had it not executed the backtracer.

The reason for doing this is that it avoids the problems of trying to generate a
symbolicated backtrace from a crashed process, which include:

* Data structures in the crashed process may be in an invalid state.  This
  includes critical structures such as the process heap.

* The crash may happen at any point; on UNIX systems the upshot is that it is
  only safe to do things that are async-signal-safe.  There is a very small list
  of those things; essentially, system calls plus a handful of POSIX functions.
  Similar problems exist on Windows.

* If the backtracer itself crashed while trying to backtrace in-process, which
  is not unlikely given that the crashing process might have corrupted various
  data structures, it would obscure the actual crash.  This is particularly bad
  on systems with a system-wide crash catcher, where the result will be a
  spurious crash rather than the actual cause.

By running out-of-process, the backtracer has a lot more flexibility in terms of
what it can do, and is also a lot safer.

### Notes on the platform-specific interface

The program is generally started with a hexadecimal encoded pointer in
`argv[1]`.  This pointer points to information about the crash that is
being handled; the exact data present is platform specific.

Note that we strongly recommend against normal application programs trying to do
any of the things we're doing here(!)

#### macOS

The program is started with the parent process's task port in the well known
ports array.

#### Linux

On Linux, fd `4` must be a UNIX domain socket connected to a small server
program built into the runtime.  This allows `swift-backtrace` to read the
crashing process's memory without using `ptrace(2)` or `process_vm_readv(2)`.
We don't want to use the latter two functions because they require the
capability `CAP_SYS_PTRACE`, which is turned off by default for normal Docker
containers.  Additionally, depending on the Linux distribution, you may need to
change the parameter `kernel.yama.ptrace_scope` to make them work, which, again,
is not desirable for Swift on Server usage.

#### Windows

The program is started with a hexadecimal encoded `HANDLE` in `argv[2]`; this is
the handle to the parent process.
