Backtracing support in Swift
============================

When things go wrong, it's always useful to be able to get a backtrace showing
where the problem occurred in your program.

Broadly speaking there are three circumstances where you might want a backtrace,
namely:

  * Program crashes
  * Runtime errors
  * Specific user-defined program events

Historically, Swift has tended to lean on operating system crash catching
support for the first two of these, and hasn't really provided any built-in
support for the latter.  This is fine for Darwin, where the operating system
provides a comprehensive system-wide crash catching facility; it's just about OK
on Windows, which also has system-wide crash logging; but it isn't great
elsewhere, in particular on Linux where a lot of server-side Swift programs
currently rely on a separate package to provide them with some level of
backtrace support when errors happen.

What does Swift now support?
----------------------------

Swift now supports:

  * Automatic crash catching and backtrace generation out of the box.
  * Built-in symbolication.
  * A choice of unwind algorithms, including "fast", DWARF and SEH.
  * Interactive(!) crash/runtime error catching.

Crash catching is enabled by default, and won't interfere with any system-wide
crash reporters you might be using.

How do I configure backtracing?
-------------------------------

There is an environment variable, ``SWIFT_BACKTRACING``, that can be used to
configure Swift's crash catching and backtracing support.  The variable should
contain a ``,``-separated list of ``key=value`` pairs.  Supported keys are as
follows:

+-----------------+---------+--------------------------------------------------+
| Key             | Default | Meaning                                          |
+=================+=========+==================================================+
| enable          | yes*    | Set to ``no`` to disable crash catching, or      |
|                 |         | ``tty`` to enable only if stdin is a terminal.   |
+-----------------+---------+--------------------------------------------------+
| symbolicate     | yes     | Set to ``no`` to disable symbolication.          |
+-----------------+---------+--------------------------------------------------+
| interactive     | tty     | Set to ``no`` to disable interaction, or ``yes`` |
|                 |         | to enable always.                                |
+-----------------+---------+--------------------------------------------------+
| color           | tty     | Set to ``yes`` to enable always, or ``no`` to    |
|                 |         | disable.  Uses ANSI escape sequences.            |
+-----------------+---------+--------------------------------------------------+
| timeout         | 30s     | Time to wait for interaction when a crash        |
|                 |         | occurs.  Setting this to ``0s`` will disable     |
|                 |         | interaction.                                     |
+-----------------+---------+--------------------------------------------------+
| unwind          | auto    | Specifies which unwind algorithm to use.         |
|                 |         | ``auto`` means to choose appropriately for the   |
|                 |         | platform.  Other options are ``fast``, which     |
|                 |         | does a naïve stack walk; ``DWARF``, which uses   |
|                 |         | the exception handling unwind information to     |
|                 |         | walk the stack; and ``SEH``, which uses Windows  |
|                 |         | APIs to perform a stack walk.                    |
+-----------------+---------+--------------------------------------------------+
| level           | 1       | Specifies the level of verbosity for the         |
|                 |         | backtrace.                                       |
+-----------------+---------+--------------------------------------------------+
| swift-backtrace |         | If specified, gives the full path to the         |
|                 |         | swift-backtrace binary to use for crashes.       |
|                 |         | Otherwise, Swift will locate the binary relative |
|                 |         | to the runtime library, or using ``SWIFT_ROOT``. |
+-----------------+---------+--------------------------------------------------+

(*) On macOS, this defaults to ``tty`` rather than ``yes``.

What is the swift-backtrace binary?
-----------------------------------

``swift-backtrace`` is a program that gets invoked when your program crashes.
We do this because when a program crashes, it is potentially in an invalid state
and there is very little that is safe for us to do.  By executing an external
helper program, we ensure that we do not interfere with the way the program was
going to crash (so that system-wide crash catchers will still generate the
correct information), and we are also able to use any functionality we need to
generate a decent backtrace, including symbolication (which might in general
require memory allocation, fetching and reading remote files and so on).

You shouldn't try to run ``swift-backtrace`` yourself; it has unusual
requirements, which vary from platform to platform.  Instead, it will be
triggered automatically by the runtime.
