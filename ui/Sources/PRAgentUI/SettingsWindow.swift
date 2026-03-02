import SwiftUI
import AppKit
import Yams

class SettingsController {
    static let shared = SettingsController()
    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsContent(onClose: { [weak self] in
            self?.window?.close()
            self?.window = nil
        })

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 620)

        let w = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.title = "PR Agent Settings"
        w.contentView = hostingView
        w.isFloatingPanel = true
        w.level = .floating
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }
}

// MARK: - gh CLI helper

private func ghExecutablePath() -> String {
    let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    for path in candidates {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return "/opt/homebrew/bin/gh"
}

private func runGH(_ arguments: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: ghExecutablePath())
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return ""
    }
    // Read pipe before waitUntilExit to avoid deadlock on large output
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Settings View

private struct SettingsContent: View {
    let onClose: () -> Void

    @State private var org: String = ""

    // Excluded repos
    @State private var allRepos: [String] = []
    @State private var skippedRepos: Set<String> = []
    @State private var isLoadingRepos = true
    @State private var repoFilter = ""

    // Auto-comment users
    @State private var allMembers: [String] = []
    @State private var autoCommentUsers: Set<String> = []
    @State private var isLoadingMembers = true
    @State private var memberFilter = ""
    @State private var manualUsername = ""

    // Concurrency
    @State private var maxConcurrentReviews: Int = 2

    @State private var savedIndicator = false

    private let configPath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.pr-agent/config.yaml"
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Excluded Repos")
                    .font(.headline)
                Text("Checked repos are skipped during polling — no reviews will be created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Filter repos...", text: $repoFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                if isLoadingRepos {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Loading repos...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                } else if allRepos.isEmpty {
                    Text("No repos found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(filteredRepos, id: \.self) { repo in
                                HStack {
                                    Toggle(isOn: binding(for: repo, in: $skippedRepos)) {
                                        Text(repo)
                                            .font(.system(size: 12, design: .monospaced))
                                    }
                                    .toggleStyle(.checkbox)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(6)
                }
            }
            .padding(.bottom, 14)

            Divider()
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Max Concurrent Reviews")
                        .font(.headline)
                    Spacer()
                    Stepper(value: $maxConcurrentReviews, in: 1...10) {
                        Text("\(maxConcurrentReviews)")
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minWidth: 20, alignment: .trailing)
                    }
                }
                Text("How many reviews can run in parallel. Higher values use more CPU and API quota.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)

            Divider()
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 6) {
                Text("Auto-Comment Users")
                    .font(.headline)
                Text("For checked users, Claude will post review comments directly on the PR but will not approve until you say so.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Filter members...", text: $memberFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                HStack(spacing: 4) {
                    TextField("Add bot or external user...", text: $manualUsername)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { addManualUser() }
                    Button("Add") { addManualUser() }
                        .font(.caption)
                        .disabled(manualUsername.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if isLoadingMembers {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Loading org members...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                } else if allMembers.isEmpty {
                    Text("No members found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(filteredMembers, id: \.self) { member in
                                HStack {
                                    Toggle(isOn: binding(for: member, in: $autoCommentUsers)) {
                                        Text(member)
                                            .font(.system(size: 12, design: .monospaced))
                                    }
                                    .toggleStyle(.checkbox)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(6)
                }
            }

            Spacer()

            HStack {
                Spacer()
                if savedIndicator {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 520)
        .onAppear {
            loadConfig()
            fetchRepos()
            fetchMembers()
        }
    }

    // MARK: - Filtering

    private var filteredRepos: [String] {
        if repoFilter.isEmpty { return allRepos }
        return allRepos.filter { $0.localizedCaseInsensitiveContains(repoFilter) }
    }

    private var filteredMembers: [String] {
        // Merge org members with any manually-added users (bots, external users)
        let manualUsers = autoCommentUsers.subtracting(allMembers)
        let combined = (allMembers + manualUsers.sorted()).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        if memberFilter.isEmpty { return combined }
        return combined.filter { $0.localizedCaseInsensitiveContains(memberFilter) }
    }

    // MARK: - Toggle binding helper

    private func binding(for item: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(item) },
            set: { checked in
                if checked { set.wrappedValue.insert(item) }
                else { set.wrappedValue.remove(item) }
            }
        )
    }

    // MARK: - Manual user entry

    private func addManualUser() {
        let username = manualUsername.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else { return }
        // Reject characters that would corrupt YAML
        let invalidChars = CharacterSet.newlines.union(CharacterSet(charactersIn: ":#"))
        guard username.rangeOfCharacter(from: invalidChars) == nil else { return }
        autoCommentUsers.insert(username)
        manualUsername = ""
    }

    // MARK: - Load config

    private func loadConfig() {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8),
              let yaml = try? Yams.load(yaml: content) as? [String: Any] else { return }

        org = yaml["github_org"] as? String ?? ""

        if let repos = yaml["skip_repos"] as? [String] {
            skippedRepos = Set(repos)
        }
        if let users = yaml["auto_comment_users"] as? [String] {
            autoCommentUsers = Set(users)
        }
        if let concurrency = yaml["max_concurrent_reviews"] as? Int {
            maxConcurrentReviews = concurrency
        }
    }

    // MARK: - Fetch from GitHub

    private func fetchRepos() {
        guard !org.isEmpty else {
            isLoadingRepos = false
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let output = runGH(["api", "orgs/\(org)/repos", "--paginate", "--jq", ".[].name"])
            let repos = output
                .split(separator: "\n")
                .map(String.init)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

            DispatchQueue.main.async {
                allRepos = repos
                isLoadingRepos = false
            }
        }
    }

    private func fetchMembers() {
        guard !org.isEmpty else {
            isLoadingMembers = false
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let output = runGH(["api", "orgs/\(org)/members", "--paginate", "--jq", ".[].login"])
            let members = output
                .split(separator: "\n")
                .map(String.init)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

            DispatchQueue.main.async {
                allMembers = members
                isLoadingMembers = false
            }
        }
    }

    // MARK: - Save

    private func save() {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        content = replaceYamlList(in: content, key: "skip_repos", values: skippedRepos.sorted())
        content = replaceYamlList(in: content, key: "auto_comment_users", values: autoCommentUsers.sorted())
        content = replaceYamlScalar(in: content, key: "max_concurrent_reviews", value: "\(maxConcurrentReviews)")

        do {
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
        } catch {
            return  // Don't show "Saved" if write failed
        }

        withAnimation { savedIndicator = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { savedIndicator = false }
        }
    }

    /// Replace or insert a simple YAML scalar (key: value)
    private func replaceYamlScalar(in content: String, key: String, value: String) -> String {
        var result = content
        let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: key) + ":.*$"
        if let range = result.range(of: pattern, options: .regularExpression) {
            result.replaceSubrange(range, with: "\(key): \(value)")
        } else {
            result += "\n\(key): \(value)\n"
        }
        return result
    }

    /// Replace or insert a YAML list block (key: \n  - item1 \n  - item2)
    private func replaceYamlList(in content: String, key: String, values: [String]) -> String {
        var result = content

        let newBlock: String
        if values.isEmpty {
            newBlock = "\(key): []\n"
        } else {
            let items = values.map { "  - \($0)" }.joined(separator: "\n")
            newBlock = "\(key):\n\(items)\n"
        }

        // Match: key followed by either [] or indented list items
        // Pattern covers: "key: []", "key:\n  - a\n  - b\n", and "key:" with trailing content
        let listPattern = "(?m)^" + NSRegularExpression.escapedPattern(for: key) + ":.*\\n(?:  - [^\\n]+\\n)*"
        if let range = result.range(of: listPattern, options: .regularExpression) {
            result.replaceSubrange(range, with: newBlock)
        } else {
            // Key not present — append before first blank line or at end
            result += "\n\(newBlock)"
        }

        return result
    }
}
