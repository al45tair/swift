//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
import Darwin.C
import Darwin.Mach
#elseif canImport(Glibc)
import Glibc
#elseif canImport(MSVCRT)
import MSVCRT
#endif

@main
internal struct SwiftBacktrace {
  enum UnwindAlgorithm {
    case Fast
    case Precise
  }

  struct Arguments {
    var unwindAlgorithm: UnwindAlgorithm = .Precise
    var symbolicate = false
    var interactive = false
    var color = false
    var timeout = 30
    var level = 1
    var crashInfo: UInt64? = nil
  }

  static var args = Arguments()

  static var target: Target? = nil

  static func usage() {
    print("""
usage: swift-backtrace [--unwind <algorithm>] [--symbolicate [<bool>]] [--interactive [<bool>]] [--color [<bool>]] [--timeout <seconds>] [--level <level>] --crashinfo <addr>

Generate a backtrace for the parent process.

--unwind <algorithm>
-u <algorithm>          Set the unwind algorithm to use.  Supported algorithms
                        are "fast" and "precise".

--symbolicate [<bool>]
-s [<bool>]             Set whether or not to symbolicate.

--interactive [<bool>]
-i [<bool>]             Set whether to be interactive.

--color [<bool>]
-c [<bool>]             Set whether to use ANSI color in the output.

--timeout <seconds>
-t <seconds>            Set how long to wait for interaction.

--level <level>
-l <level>              Set the initial verbosity level.

--crashinfo <addr>
-a <addr>               Provide a pointer to a platform specific CrashInfo
                        structure.  <addr> should be in hexadecimal.
""")
  }

  static func handleArgument(_ arg: String, value: String?) {
    switch arg {
      case "-?", "-h", "--help":
        usage()
        exit(0)
      case "-u", "--unwind":
        if let v = value {
          switch v.lowercased() {
            case "fast":
              args.unwindAlgorithm = .Fast
            case "precise":
              args.unwindAlgorithm = .Precise
            default:
              print("swift-backtrace: unknown unwind algorithm '\(v)'")
              usage()
              exit(1)
          }
        } else {
          print("swift-backtrace: missing unwind algorithm")
          usage()
          exit(1)
        }
      case "-s", "--symbolicate":
        if let v = value {
          args.symbolicate = v.lowercased() == "true"
        } else {
          args.symbolicate = true
        }
      case "-i", "--interactive":
        if let v = value {
          args.interactive = v.lowercased() == "true"
        } else {
          args.interactive = true
        }
      case "-c", "--color":
        if let v = value {
          args.color = v.lowercased() == "true"
        } else {
          args.color = true
        }
      case "-t", "--timeout":
        if let v = value {
          if let secs = Int(v), secs >= 0 {
            args.timeout = secs
          } else {
            print("bad timeout '\(v)'")
          }
        } else {
          print("swift-backtrace: missing timeout value")
          usage()
          exit(1)
        }
      case "-l", "--level":
        if let v = value {
          if let l = Int(v), l > 0 {
            args.level = l
          } else {
            print("swift-backtrace: bad verbosity level '\(v)'")
            usage()
            exit(1)
          }
        } else {
          print("swift-backtrace: missing verbosity level")
          usage()
          exit(1)
        }
      case "-a", "--crashinfo":
        if let v = value {
          if let a = UInt64(v, radix: 16) {
            args.crashInfo = a
          } else {
            print("swift-backtrace: bad pointer '\(v)'")
            usage()
            exit(1)
          }
        } else {
          print("swift-backtrace: missing pointer value")
          usage()
          exit(1)
        }
      default:
        print("swift-backtrace: unknown argument '\(arg)'")
        usage()
        exit(1)
    }
  }

  static func main() {
    // Parse the command line arguments; we can't use swift-argument-parser
    // from here because that would create a dependency problem, so we do
    // it manually.
    var currentArg: String? = nil
    for arg in CommandLine.arguments[1...] {
      if arg.hasPrefix("-") {
        if let key = currentArg {
          handleArgument(key, value: nil)
        }
        currentArg = arg
      } else {
        if let key = currentArg {
          handleArgument(key, value: arg)
          currentArg = nil
        } else {
          print("swift-backtrace: unexpected argument '\(arg)'")
          usage()
          exit(1)
        }
      }
    }
    if let key = currentArg {
      handleArgument(key, value: nil)
    }

    guard let crashInfoAddr = args.crashInfo else {
      print("swift-backtrace: --crashinfo is not optional")
      usage()
      exit(1)
    }

    target = Target(crashInfoAddr: crashInfoAddr)

    printCrashLog()

    if args.interactive {
      if let ch = waitForKey("Press space to interact, or any other key to quit",
                             timeout: args.timeout),
         ch == UInt8(ascii: " ") {
        interactWithUser()
      }
    }

  }

  #if os(Linux) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
  static func setRawMode() -> termios {
    var oldAttrs = termios()
    tcgetattr(0, &oldAttrs)

    var newAttrs = oldAttrs
    newAttrs.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
    tcsetattr(0, TCSANOW, &newAttrs)

    return oldAttrs
  }

  static func resetInputMode(mode: termios) {
    var theMode = mode
    tcsetattr(0, TCSANOW, &theMode)
  }

  static func waitForKey(_ message: String, timeout: Int) -> Int32? {
    let oldMode = setRawMode()

    defer {
      print("\r\u{1b}[0K", terminator: "")
      fflush(stdout)
      resetInputMode(mode: oldMode)
    }

    var remaining = timeout

    while true {
      print("\r\(message) (\(remaining)s) ", terminator: "")
      fflush(stdout)

      var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)

      let ret = poll(&pfd, 1, 1000)
      if ret == 0 {
        remaining -= 1
        if remaining == 0 {
          break
        }
        continue
      } else if ret < 0 {
        break
      }

      let ch = getchar()
      return ch
    }

    return nil
  }
  #elseif os(Windows)
  static func waitForKey(_ message: String, timeout: Int) -> Int32? {
    // ###TODO
    return nil
  }
  #endif

  static func printCrashLog() {
    guard let target = target else {
      print("swift-backtrace: unable to get target")
      return
    }

    guard let crashingThread = target.threads[target.crashingThread] else {
      print("swift-backtrace: unable to find crashing thread")
      return
    }

    print("""
            Process \(target.pid) crashed in thread \(target.crashingThread) "\(crashingThread.name)"

            Signal: \(target.signal) \(target.signalName)
            Fault address: \(hex(target.faultAddress))

            """)

    print(crashingThread.backtrace)
  }

  static func interactWithUser() {
    while true {
      print(">>> ", terminator: "")
      guard let input = readLine() else {
        print("")
        break
      }

      let cmd = input.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })

      if cmd.count < 1 {
        continue
      }

      switch cmd[0].lowercased() {
        case "exit", "quit":
          return
        case "help":
          print("""
                  Available commands:

                  exit   Exit interaction, allowing program to crash normally.
                  quit   Synonym for exit

                  """)
        default:
          print("unknown command '\(cmd[0])'")
      }
    }
  }
}
