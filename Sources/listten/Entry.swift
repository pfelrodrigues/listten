import AppKit
import Foundation
import ListtenCore

// One binary, two modes: no arguments runs the menu bar agent, arguments run the CLI.
@main
enum Entry {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        switch args.first {
        case nil:
            runAgent()
        case "--version", "-v":
            print(Listten.version)
        case "--help", "-h":
            printUsage()
        default:
            FileHandle.standardError.write(Data("unknown command: \(args[0])\n".utf8))
            exit(64)
        }
    }

    @MainActor
    private static func runAgent() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "L"

        let menu = NSMenu()
        menu.addItem(withTitle: "Listten \(Listten.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu

        app.run()
        exit(0)
    }

    private static func printUsage() {
        print(
            """
            listten \(Listten.version)

            Usage:
              listten             run the menu bar agent
              listten <command>   run a command and exit

            Options:
              -v, --version   print the version
              -h, --help      print this help
            """
        )
    }
}
