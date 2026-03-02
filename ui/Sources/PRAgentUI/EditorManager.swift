import Foundation
import AppKit

struct KnownEditor: Identifiable {
    let id: String
    let displayName: String
    let bundleId: String?
    let cliCommand: String?
    let isTerminal: Bool

    var isInstalled: Bool {
        if let bundleId = bundleId,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil {
            return true
        }
        if let cli = cliCommand {
            return Self.commandExists(cli)
        }
        return false
    }

    var appURL: URL? {
        guard let bundleId = bundleId else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    private static func commandExists(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        // macOS GUI apps have a minimal PATH; add common install locations
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

class EditorManager: ObservableObject {

    static let registry: [KnownEditor] = [
        KnownEditor(id: "cursor",    displayName: "Cursor",        bundleId: "com.todesktop.230313mzl4w4u92", cliCommand: "cursor",    isTerminal: false),
        KnownEditor(id: "vscode",    displayName: "VS Code",       bundleId: "com.microsoft.VSCode",          cliCommand: "code",      isTerminal: false),
        KnownEditor(id: "zed",       displayName: "Zed",           bundleId: "dev.zed.Zed",                   cliCommand: "zed",       isTerminal: false),
        KnownEditor(id: "xcode",     displayName: "Xcode",         bundleId: "com.apple.dt.Xcode",            cliCommand: "xed",       isTerminal: false),
        KnownEditor(id: "idea",      displayName: "IntelliJ IDEA", bundleId: "com.jetbrains.intellij",        cliCommand: "idea",      isTerminal: false),
        KnownEditor(id: "webstorm",  displayName: "WebStorm",      bundleId: "com.jetbrains.WebStorm",        cliCommand: "webstorm",  isTerminal: false),
        KnownEditor(id: "pycharm",   displayName: "PyCharm",       bundleId: "com.jetbrains.pycharm",         cliCommand: "pycharm",   isTerminal: false),
        KnownEditor(id: "goland",    displayName: "GoLand",        bundleId: "com.jetbrains.goland",          cliCommand: "goland",    isTerminal: false),
        KnownEditor(id: "clion",     displayName: "CLion",         bundleId: "com.jetbrains.CLion",           cliCommand: "clion",     isTerminal: false),
        KnownEditor(id: "rubymine",  displayName: "RubyMine",      bundleId: "com.jetbrains.rubymine",        cliCommand: "rubymine",  isTerminal: false),
        KnownEditor(id: "rider",     displayName: "Rider",         bundleId: "com.jetbrains.rider",           cliCommand: "rider",     isTerminal: false),
        KnownEditor(id: "emacs",     displayName: "Emacs",         bundleId: "org.gnu.Emacs",                 cliCommand: "emacs",     isTerminal: false),
        KnownEditor(id: "nvim",      displayName: "Neovim",        bundleId: nil,                             cliCommand: "nvim",      isTerminal: true),
        KnownEditor(id: "vim",       displayName: "Vim",           bundleId: nil,                             cliCommand: "vim",       isTerminal: true),
    ]

    @Published var installedEditors: [KnownEditor] = []
    @Published var selectedEditorId: String? = nil

    private let configPath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.pr-agent/config.yaml"
    }()

    init() {
        refreshInstalledEditors()
        selectedEditorId = readEditorFromConfig()
    }

    func refreshInstalledEditors() {
        installedEditors = Self.registry.filter { $0.isInstalled }
    }

    var hasEditor: Bool {
        selectedEditorId != nil
    }

    // MARK: - Config read/write

    func readEditorFromConfig() -> String? {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ide:") && !trimmed.hasPrefix("#") {
                let value = String(trimmed.dropFirst("ide:".count)).trimmingCharacters(in: .whitespaces)
                let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return unquoted.isEmpty ? nil : unquoted
            }
        }
        return nil
    }

    func selectEditor(_ editorId: String?) {
        selectedEditorId = editorId
        saveEditorToConfig(editorId)
    }

    private func saveEditorToConfig(_ editorId: String?) {
        let configURL = URL(fileURLWithPath: configPath)
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var content = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        // Remove existing editor line (commented or not)
        let lines = content.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Keep lines that aren't editor-related
            if trimmed == "# ide:" || trimmed.hasPrefix("ide:") { return false }
            if trimmed.hasPrefix("# ide:") { return false }
            // Keep the comment about what editor does
            if trimmed.hasPrefix("# IDE") { return false }
            return true
        }
        content = filtered.joined(separator: "\n")

        // Remove trailing blank lines, keep one newline at end
        while content.hasSuffix("\n\n") {
            content = String(content.dropLast())
        }
        if !content.hasSuffix("\n") {
            content += "\n"
        }

        // Append the editor setting
        if let editorId = editorId {
            let escaped = editorId
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            content += "\n# IDE for opening review clones\nide: \"\(escaped)\"\n"
        }

        try? content.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Opening

    func openInEditor(_ path: String) {
        guard let editorId = selectedEditorId else { return }

        // Look up in registry
        if let known = Self.registry.first(where: { $0.id == editorId }) {
            if known.isTerminal {
                openInTerminal(command: known.cliCommand ?? editorId, path: path)
            } else if let appURL = known.appURL {
                openWithApp(appURL: appURL, path: path)
            } else if let cli = known.cliCommand {
                openWithCLI(command: cli, path: path)
            }
        } else {
            // Custom command — treat as CLI
            openWithCLI(command: editorId, path: path)
        }
    }

    private func openWithApp(appURL: URL, path: String) {
        let dirURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([dirURL], withApplicationAt: appURL, configuration: config)
    }

    private func openWithCLI(command: String, path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [command, path]
        try? task.run()
    }

    private func openInTerminal(command: String, path: String) {
        // Use a .command file to avoid AppleScript and TCC permission dialogs
        // Use a unique temp file to avoid race conditions with concurrent launches
        let launcherPath = NSTemporaryDirectory() + "pr-agent-editor-\(UUID().uuidString).command"
        // Shell-escape command and path to prevent injection
        let safeCommand = command.replacingOccurrences(of: "'", with: "'\\''")
        let safePath = path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/bash\nexport TERM=\"${TERM:-xterm-256color}\"\ntput reset 2>/dev/null\nexec '\(safeCommand)' '\(safePath)'\n"

        try? script.write(toFile: launcherPath, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", launcherPath]
        try? chmod.run()
        chmod.waitUntilExit()

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if FileManager.default.fileExists(atPath: "/Applications/iTerm.app") {
            open.arguments = ["-a", "iTerm", launcherPath]
        } else {
            open.arguments = [launcherPath]
        }
        try? open.run()
    }
}
