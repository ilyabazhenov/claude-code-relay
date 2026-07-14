import Foundation

/// Headless command-line entry points, used for scripting and testing without the
/// GUI.
enum CLI {
    static func printUsage() {
        print("""
        Relay — dispatcher for Claude Code sessions

        Usage:
          Relay                     Launch the menu-bar app (default)
          Relay --install-hooks     Install Claude Code hooks for the current user
          Relay --uninstall-hooks   Remove Relay's Claude Code hooks
          Relay --help              Show this help
        """)
    }

    static func installHooks() -> Int32 {
        let config: Config
        do {
            config = try ConfigStore.loadOrCreate()
        } catch {
            FileHandle.standardError.write(Data("error: cannot read config: \(error)\n".utf8))
            return 1
        }
        guard config.port != 0 else {
            FileHandle.standardError.write(Data("""
            error: no daemon port yet. Launch Relay.app once so it can bind a port,
                   then re-run `--install-hooks`.\n
            """.utf8))
            return 1
        }
        do {
            try HooksInstaller.install(port: config.port, secret: config.secret,
                                       approvalsEnabled: config.effectiveApprovalsEnabled)
            print("Installed Relay hooks (daemon port \(config.port)).")
            print("Scripts: \(HooksInstaller.scriptsDir.path)")
            print("Settings: \(HooksInstaller.settingsURL.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: install failed: \(error)\n".utf8))
            return 1
        }
    }

    static func uninstallHooks() -> Int32 {
        do {
            try HooksInstaller.uninstall()
            print("Removed Relay hooks from \(HooksInstaller.settingsURL.path).")
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: uninstall failed: \(error)\n".utf8))
            return 1
        }
    }
}
