// computer-use-mcp — entry point.

import CoreGraphics
import Foundation

// Establish the window-server connection on the main thread before any
// CoreGraphics/ScreenCaptureKit call runs on a worker thread; without this,
// CG asserts (CGS_REQUIRE_INIT) in headless CLI processes.
_ = CGMainDisplayID()

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "serve":
    await runServe()
case "call":
    await runCall(Array(arguments.dropFirst()))
case "doctor":
    runDoctor(prompt: arguments.contains("--prompt"))
case "overlay":
    runOverlay()
case "version", "--version", "-v":
    print("computer-use-mcp \(version)")
case "help", "--help", "-h", .none:
    printUsage()
case .some(let unknown):
    FileHandle.standardError.write(Data("Unknown command: \(unknown)\n\n".utf8))
    printUsage()
    exit(2)
}

func printUsage() {
    print(
        """
        computer-use-mcp \(version)
        Expose macOS computer use to any AI agent, over MCP.

        USAGE:
          computer-use-mcp serve                 Run the MCP server over stdio
          computer-use-mcp call <tool> [<json>]  Invoke a single tool (dev harness)
          computer-use-mcp doctor [--prompt]     Check required macOS permissions
          computer-use-mcp version               Print version
          computer-use-mcp help                  Show this help
        """
    )
}
