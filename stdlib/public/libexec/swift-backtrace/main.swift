//===----------------------------------------------------------------------===//
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

#if canImport(Darwin)
import Darwin.C
#elseif canImport(Glibc)
import Glibc
#elseif canImport(MSVCRT)
import MSVCRT
#endif

@_spi(Internal) import _Backtracing

@main
internal struct SwiftBacktrace {
  enum UnwindAlgorithm {
    case Fast
    case Precise
  }

  static var unwindAlgorithm: UnwindAlgorithm = .DWARF
  static var symbolicate = false
  static var interactive = false
  static var color = false
  static var timeout = 30
  static var level = 1
  static var crashInfo: UInt64? = nil

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
          switch v {
            case "fast", "Fast", "FAST":
              unwindAlgorithm = .Fast
            case "precise", "Precise", "PRECISE":
              unwindAlgorithm = .Precise
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
          symbolicate = v == "true"
        } else {
          symbolicate = true
        }
      case "-i", "--interactive":
        if let v = value {
          interactive = v == "true"
        } else {
          interactive = true
        }
      case "-c", "--color":
        if let v = value {
          color = v == "true"
        } else {
          color = true
        }
      case "-t", "--timeout":
        if let v = value {
          if let secs = Int(v), secs >= 0 {
            timeout = secs
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
            level = l
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
            crashInfo = a
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

    if crashInfo == nil {
      print("swift-backtrace: --crashinfo is not optional")
      usage()
      exit(1)
    }

    print("SWIFT BACKTRACE INVOKED!")

  }
}
