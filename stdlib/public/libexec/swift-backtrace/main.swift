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

@_spi(Formatting) import _Backtracing
@_spi(Contexts) import _Backtracing
@_spi(Registers) import _Backtracing
@_spi(MemoryReaders) import _Backtracing

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
  static var currentThread: Int = 0

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

    currentThread = target!.crashingThreadNdx

    printCrashLog()

    print("")

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

  static func backtraceFormatter() -> BacktraceFormatter {
    var terminalSize = winsize(ws_row: 24, ws_col: 80,
                               ws_xpixel: 1024, ws_ypixel: 768)
    _ = ioctl(0, TIOCGWINSZ, &terminalSize)

    let theme: BacktraceFormattingThemeProtocol = args.color ? BacktraceFormatter.Themes.color : BacktraceFormatter.Themes.plain
    return BacktraceFormatter(.theme(theme)
                              .showAddresses(false)
                              .showSourceCode(true)
                              .showFrameAttributes(false)
                              .skipRuntimeFailures(true)
                              .sanitizePaths(false)
                              .width(Int(terminalSize.ws_col)))
  }

  static func printCrashLog() {
    guard let target = target else {
      print("swift-backtrace: unable to get target")
      return
    }

    let crashingThread = target.threads[target.crashingThreadNdx]

    let description: String

    if let failure = crashingThread.backtrace.swiftRuntimeFailure {
      description = failure
    } else {
      description = "Program crashed: \(target.signalDescription) at \(hex(target.faultAddress))"
    }

    print("")
    if args.color {
      print("\u{1b}[91m\(description)\u{1b}[0m")
    } else {
      print("*** \(description) ***")
    }
    print("")

    if crashingThread.name.isEmpty {
      print("Thread \(target.crashingThreadNdx) crashed:\n")
    } else {
      print("Thread \(target.crashingThreadNdx) \"\(crashingThread.name)\" crashed:\n")
    }

    let formatter = backtraceFormatter()
    let formatted = formatter.format(backtrace: crashingThread.backtrace)

    print(formatted)
  }

  static func interactWithUser() {
    guard let target = target else {
      return
    }

    while true {
      print(">>> ", terminator: "")
      guard let input = readLine() else {
        print("")
        break
      }

      let cmd = input.split(whereSeparator: { $0.isWhitespace })

      if cmd.count < 1 {
        continue
      }

      // ###TODO: We should really replace this with something a little neater
      switch cmd[0].lowercased() {
        case "exit", "quit":
          return
        case "bt", "backtrace":
          let formatter = backtraceFormatter()
          let backtrace = target.threads[currentThread].backtrace
          let formatted = formatter.format(backtrace: backtrace)

          print(formatted)
        case "thread":
          if cmd.count >= 2 {
            if let newThreadNdx = Int(cmd[1]),
               newThreadNdx >= 0 && newThreadNdx < target.threads.count {
              currentThread = newThreadNdx
            } else {
              print("Bad thread index '\(cmd[1])'")
              break
            }
          }

          let crashed: String
          if currentThread == target.crashingThreadNdx {
            crashed = " (crashed)"
          } else {
            crashed = ""
          }

          let thread = target.threads[currentThread]
          let backtrace = thread.backtrace
          let name = thread.name.isEmpty ? "" : " \(thread.name)"
          print("Thread \(currentThread) id=\(thread.id)\(name)\(crashed)\n")

          if backtrace.frames.count > 0 {
            let frame: SymbolicatedBacktrace.Frame
            if backtrace.isSwiftRuntimeFailure {
              frame = backtrace.frames[1]
            } else {
              frame = backtrace.frames[0]
            }

            let formatter = backtraceFormatter()
            let formatted = formatter.format(frame: frame)
            print("\(formatted)")
          }
          break
        case "reg", "registers":
          if let context = target.threads[currentThread].context {
            showRegisters(context)
          } else {
            print("No context for thread \(currentThread)")
          }
          break
        case "mem", "memory":
          if cmd.count != 2 && cmd.count != 3 {
            print("memory <start-address> [<end-address>|+<byte-count>]")
            break
          }

          guard let startAddress = parseUInt64(cmd[1]) else {
            print("Bad start address \(cmd[1])")
            break
          }

          let count: UInt64
          if cmd.count == 3 {
            if cmd[2].hasPrefix("+") {
              guard let theCount = parseUInt64(cmd[2].dropFirst()) else {
                print("Bad byte count \(cmd[2])")
                break
              }
              count = theCount
            } else {
              guard let addr = parseUInt64(cmd[2]) else {
                print("Bad end address \(cmd[2])")
                break
              }
              if addr < startAddress {
                print("End address must be after start address")
                break
              }
              count = addr - startAddress
            }
          } else {
            count = 256
          }

          dumpMemory(at: startAddress, count: count)
          break
        case "process", "threads":
          print("Process \(target.pid) \"\(target.name)\" has \(target.threads.count) thread(s):\n")

          let formatter = backtraceFormatter()

          var rows: [BacktraceFormatter.TableRow] = []
          for (n, thread) in target.threads.enumerated() {
            let backtrace = thread.backtrace

            let crashed: String
            if n == target.crashingThreadNdx {
              crashed = " (crashed)"
            } else {
              crashed = ""
            }

            let selected = currentThread == n ? "*" : " "
            let name = thread.name.isEmpty ? "" : " \(thread.name)"

            rows.append(.columns([ selected,
                                   "\(n)",
                                   "id=\(thread.id)\(name)\(crashed)" ]))

            if backtrace.frames.count > 0 {
              let frame: SymbolicatedBacktrace.Frame
              if backtrace.isSwiftRuntimeFailure {
                frame = backtrace.frames[1]
              } else {
                frame = backtrace.frames[0]
              }

              rows += formatter.formatRows(frame: frame).map{ row in
                switch row {
                  case let .columns(columns):
                    return .columns([ "", "" ] + columns)
                  default:
                    return row
                }
              }
            }
          }

          let output = BacktraceFormatter.formatTable(rows,
                                                      alignments: [
                                                        .left,
                                                        .right
                                                      ])
          print(output)
        case "images":
          let formatter = backtraceFormatter()
          let images = target.threads[currentThread].backtrace.images
          let output = formatter.format(images: images)

          print(output)
        case "help":
          print("""
                  Available commands:

                  backtrace  Display a backtrace.
                  bt         Synonym for backtrace.
                  exit       Exit interaction, allowing program to crash normally.
                  help       Display help.
                  images     List images loaded by the program.
                  mem        Synonym for memory.
                  memory     Inspect memory.
                  process    Show information about the process.
                  quit       Synonym for exit.
                  reg        Synonym for registers.
                  registers  Display the registers.
                  thread     Show or set the current thread.
                  threads    Synonym for process.
                  """)
        default:
          print("unknown command '\(cmd[0])'")
      }

      print("")
    }
  }

  static func printableBytes(from bytes: some Sequence<UInt8>) -> String {
    return String(
      String.UnicodeScalarView(
        bytes.map{ byte in
          let cp: UInt32
          switch byte {
            case 0..<32:
              cp = 0x2e
            case 127:
              cp = 0x2e
            case 0x80..<0xa0:
              cp = 0x2e
            default:
              cp = UInt32(byte)
          }
          return Unicode.Scalar(cp)!
        }
      )
    )
  }

  static func dumpMemory(at address: UInt64, count: UInt64) {
    guard let bytes = try? target!.reader.fetch(type: UInt8.self,
                                                from: RemoteMemoryReader.Address(address),
                                                count: Int(count)) else {
      print("Unable to read memory")
      return
    }

    let startAddress = HostContext.stripPtrAuth(address: address)
    var ndx = 0
    while ndx < bytes.count {
      let addr = startAddress + UInt64(ndx)
      let remaining = bytes.count - ndx
      let lineChunk = 16
      let todo = min(remaining, lineChunk)
      let formattedBytes = bytes[ndx..<ndx+todo].map{
        hex($0, withPrefix: false)
      }.joined(separator: " ")
      let printedBytes = printableBytes(from: bytes[ndx..<ndx+todo])
      let padding = String(repeating: " ",
                           count: lineChunk * 3 - formattedBytes.count - 1)

      print("\(hex(addr, withPrefix: false))  \(formattedBytes)\(padding)  \(printedBytes)")

      ndx += todo
    }
  }

  static func showRegister<T: FixedWidthInteger>(name: String, value: T) {
    // Pad the register name
    let regPad = String(repeating: " ", count: max(3 - name.count, 0))
    let regPadded = regPad + name

    // Grab 16 bytes at each address if possible
    if let bytes = try? target!.reader.fetch(type: UInt8.self,
                                             from: RemoteMemoryReader.Address(value),
                                             count: 16) {
      let formattedBytes = bytes.map{
        hex($0, withPrefix: false)
      }.joined(separator: " ")
      let printedBytes = printableBytes(from: bytes)
      print("\(regPadded) \(hex(value))  \(formattedBytes)  \(printedBytes)")
    } else {
      print("\(regPadded) \(hex(value))  \(value)")
    }
  }

  static func showGPR<C: Context>(name: String, context: C, register: C.Register) {
    // Get the register contents
    let value = context.getRegister(register)!

    showRegister(name: name, value: value)
  }

  static func showGPRs<C: Context, Rs: Sequence>(_ context: C, range: Rs) where Rs.Element == C.Register {
    for reg in range {
      showGPR(name: "\(reg)", context: context, register: reg)
    }
  }

  static func x86StatusFlags<T: FixedWidthInteger>(_ flags: T) -> String {
    var status: [String] = []

    if (flags & 0x400) != 0 {
      status.append("OF")
    }
    if (flags & 0x80) != 0 {
      status.append("SF")
    }
    if (flags & 0x40) != 0 {
      status.append("ZF")
    }
    if (flags & 0x10) != 0 {
      status.append("AF")
    }
    if (flags & 0x4) != 0 {
      status.append("PF")
    }
    if (flags & 0x1) != 0 {
      status.append("CF")
    }

    return status.joined(separator: " ")
  }

  static func showRegisters(_ context: X86_64Context) {
    showGPRs(context, range: .rax ... .r15)
    showRegister(name: "rip", value: context.programCounter)

    let rflags = context.getRegister(.rflags)!
    let cs = UInt16(context.getRegister(.cs)!)
    let fs = UInt16(context.getRegister(.fs)!)
    let gs = UInt16(context.getRegister(.gs)!)

    let status = x86StatusFlags(rflags)

    print("")
    print("rflags \(hex(rflags))  \(status)")
    print("")
    print("cs \(hex(cs))  fs \(hex(fs))  gs \(hex(gs))")
  }

  static func showRegisters(_ context: I386Context) {
    showGPRs(context, range: .eax ... .edi)
    showRegister(name: "eip", value: context.programCounter)

    let eflags = UInt32(context.getRegister(.eflags)!)
    let es = UInt16(context.getRegister(.es)!)
    let cs = UInt16(context.getRegister(.cs)!)
    let ss = UInt16(context.getRegister(.ss)!)
    let ds = UInt16(context.getRegister(.ds)!)
    let fs = UInt16(context.getRegister(.fs)!)
    let gs = UInt16(context.getRegister(.gs)!)

    let status = x86StatusFlags(eflags)

    print("")
    print("eflags \(hex(eflags))  \(status)")
    print("")
    print("es: \(hex(es)) cs: \(hex(cs)) ss: \(hex(ss)) ds: \(hex(ds)) fs: \(fs)) gs: \(hex(gs))")
  }

  static func showRegisters(_ context: ARM64Context) {
    showGPRs(context, range: .x0 ..< .x29)
    showGPR(name: "fp", context: context, register: .x29)
    showGPR(name: "lr", context: context, register: .x30)
    showGPR(name: "sp", context: context, register: .sp)
    showGPR(name: "pc", context: context, register: .pc)
  }

  static func showRegisters(_ context: ARMContext) {
    showGPRs(context, range: .r0 ... .r10)
    showGPR(name: "fp", context: context, register: .r11)
    showGPR(name: "ip", context: context, register: .r12)
    showGPR(name: "sp", context: context, register: .r13)
    showGPR(name: "lr", context: context, register: .r14)
    showGPR(name: "pc", context: context, register: .r15)
  }
}
