import Foundation

// Entry point. A couple of CLI subcommands run headlessly and exit before the GUI
// starts; otherwise we launch the menu-bar app.
let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    CLI.printUsage()
    exit(0)
}

if arguments.contains("--install-hooks") {
    exit(CLI.installHooks())
}

if arguments.contains("--uninstall-hooks") {
    exit(CLI.uninstallHooks())
}

RelayApp.main()
