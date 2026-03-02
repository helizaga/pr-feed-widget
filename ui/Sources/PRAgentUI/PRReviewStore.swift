import Foundation
import Combine
import AppKit

class PRReviewStore: ObservableObject {
    @Published var reviews: [PRReview] = []
    @Published var searchQuery: String = ""
    @Published var isWebhookRunning: Bool = false
    @Published var isPolling: Bool = false
    let editorManager = EditorManager()

    private let sessionsDir: URL
    private let prAgentHome: URL
    private let prAgentBin: String   // path to pr-agent CLI (e.g. ~/.local/bin/pr-agent)
    private let prAgentDir: String   // project root resolved from symlink
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var editorSink: AnyCancellable?

    var pendingCount: Int {
        reviews.filter { $0.status == .ready || $0.status == .reviewing }.count
    }

    var readyReviews: [PRReview] {
        reviews.filter { $0.status == .ready }
    }

    var reviewingReviews: [PRReview] {
        reviews.filter { $0.status == .reviewing }
    }

    var waitingReviews: [PRReview] {
        reviews.filter { $0.status == .waitingCoderabbit }
    }

    var activeReviews: [PRReview] {
        let base = searchQuery.trimmingCharacters(in: .whitespaces).isEmpty ? reviews : filteredReviews
        return base.filter { $0.status != .merged }
    }

    var mergedReviews: [PRReview] {
        let base = searchQuery.trimmingCharacters(in: .whitespaces).isEmpty ? reviews : filteredReviews
        return base.filter { $0.status == .merged }
    }

    /// Returns reviews filtered and ranked by search query
    var filteredReviews: [PRReview] {
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return reviews
        }
        return reviews
            .map { ($0, $0.searchScore(for: searchQuery)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.prAgentHome = home.appendingPathComponent(".pr-agent")
        self.sessionsDir = prAgentHome.appendingPathComponent("sessions")

        // Resolve pr-agent CLI and project root from the symlink at ~/.local/bin/pr-agent
        let bin = home.appendingPathComponent(".local/bin/pr-agent").path
        self.prAgentBin = bin
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: bin) {
            // symlink points to <project>/bin/pr-agent — go up two levels for project root
            let binURL = URL(fileURLWithPath: resolved).deletingLastPathComponent().deletingLastPathComponent()
            self.prAgentDir = binURL.path
        } else {
            // Fallback: assume pr-agent is at ~/.local/bin and project root doesn't matter
            self.prAgentDir = home.path
        }

        // Forward editorManager changes so SwiftUI views update
        editorSink = editorManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Create directory if needed
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        loadReviews()
        checkWebhookStatus()
        startWatching()
    }

    deinit {
        watcher?.cancel()
        timer?.invalidate()
    }

    func loadReviews() {
        var loaded: [PRReview] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for dir in contents {
            let metaFile = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaFile),
                  let review = try? JSONDecoder().decode(PRReview.self, from: data) else {
                continue
            }
            loaded.append(review)
        }

        // Sort by date, most recent first
        loaded.sort { a, b in
            a.createdAt > b.createdAt
        }

        DispatchQueue.main.async {
            self.reviews = loaded
        }
    }

    private func startWatching() {
        // FSEvents via GCD dispatch source on the sessions directory
        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            // Debounce: wait a beat for writes to finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.loadReviews()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        watcher = source

        // Also poll every 10 seconds as a fallback
        // (FSEvents on directories don't always fire for nested file changes)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.loadReviews()
            self?.checkWebhookStatus()
        }
    }

    func openSession(for review: PRReview) {
        // Run everything off the main thread — Process().waitUntilExit() blocks,
        // and blocking the main thread freezes the MenuBarExtra panel.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            // Try to activate an existing iTerm tab running this session
            if self?.activateExistingSession(for: review) == true {
                return
            }

            // No existing session — launch a new one
            self?.launchNewSession(for: review)
        }
    }

    /// Launch a new terminal session for the review via .command file.
    /// Must be called from a background thread.
    private func launchNewSession(for review: PRReview) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sessionDir = "\(home)/.pr-agent/sessions/\(review.prKey)"
        // Write a .command launcher — macOS opens these in the default terminal
        // without needing Apple Events (no TCC permission dialog)
        let launcherPath = "\(sessionDir)/open.command"

        var script = "#!/bin/bash\n"
        script += "export TERM=\"${TERM:-xterm-256color}\"\n"
        script += "tput reset 2>/dev/null\n"
        script += "exec \"\(home)/.local/bin/pr-agent\" open \"\(review.prKey)\"\n"

        try? script.write(toFile: launcherPath, atomically: true, encoding: .utf8)

        // Make executable and open in default terminal
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

    /// Find and activate an existing iTerm tab running this review's Claude session.
    /// Returns true if a running session was found and iTerm was brought to foreground.
    /// Must be called from a background thread.
    private func activateExistingSession(for review: PRReview) -> Bool {
        // Must have iTerm running
        guard let iTerm = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }) else {
            return false
        }

        // Find the TTY of the running session process
        guard let tty = findSessionTTY(for: review) else {
            return false
        }

        // Use NSAppleScript (inline) instead of spawning osascript so the
        // Apple Events originate from our signed app bundle. macOS TCC
        // remembers permission per (source bundle, target bundle) — so after
        // one approval it won't prompt again.
        let script = """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        "not_found"
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&error)
        let output = result?.stringValue ?? ""

        guard output == "found" else {
            // Tab not found — session process is running but iTerm tab is gone.
            // Still bring iTerm to front so user can find it.
            DispatchQueue.main.async { iTerm.activate() }
            return false
        }

        DispatchQueue.main.async {
            iTerm.activate()
        }
        return true
    }

    /// Search ps output for a running Claude or pr-agent process matching this review.
    /// Returns the full TTY device path (e.g. /dev/ttys003) if found.
    /// Must be called from a background thread.
    private func findSessionTTY(for review: PRReview) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "tty,args"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        // Read pipe BEFORE waitUntilExit to avoid deadlock when output
        // exceeds the 64KB kernel pipe buffer (ps output can be >150KB
        // with many running processes).
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Match claude --resume <sessionId>
            let matchesSession = review.sessionId != nil
                && !review.sessionId!.isEmpty
                && trimmed.contains("--resume")
                && trimmed.contains(review.sessionId!)

            // Match pr-agent open <prKey>
            let matchesPrKey = trimmed.contains("pr-agent")
                && trimmed.contains("open")
                && trimmed.contains(review.prKey)

            guard matchesSession || matchesPrKey else { continue }

            // First whitespace-delimited token is the TTY
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard let ttyPart = parts.first else { continue }
            let tty = String(ttyPart)

            // Skip header row and non-terminal processes
            if tty == "??" || tty == "TT" || tty == "-" { continue }

            return "/dev/\(tty)"
        }

        return nil
    }

    func openInIDE(_ review: PRReview) {
        guard let clonePath = review.reviewClone, !clonePath.isEmpty else {
            // Fall back to CLI if no clone path in the model
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: self.prAgentBin)
                task.arguments = ["ide", review.prKey]
                task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
                try? task.run()
                task.waitUntilExit()
            }
            return
        }
        editorManager.openInEditor(clonePath)
    }

    func openInGitHub(for review: PRReview) {
        if let url = URL(string: review.prUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    func dismiss(review: PRReview) {
        updateStatus(for: review, to: .dismissed)
    }

    func discardAll() {
        // Clear UI instantly
        reviews = []
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            task.arguments = ["discard", "all"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                self?.loadReviews()
            }
        }
    }

    func discardAndRepoll() {
        reviews = []
        isPolling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let discard = Process()
            discard.executableURL = URL(fileURLWithPath: self.prAgentBin)
            discard.arguments = ["discard", "all"]
            discard.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? discard.run()
            discard.waitUntilExit()

            let poll = Process()
            poll.executableURL = URL(fileURLWithPath: self.prAgentBin)
            poll.arguments = ["poll"]
            poll.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? poll.run()
            poll.waitUntilExit()

            DispatchQueue.main.async {
                self.isPolling = false
                self.loadReviews()
            }
        }
    }

    func runPoll() {
        isPolling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            task.arguments = ["poll"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                self.isPolling = false
                self.loadReviews()
            }
        }
    }

    func requestReview(ref: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            task.arguments = ["review", ref]
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                self.loadReviews()
            }
        }
    }

    func runSlackPoll() {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            task.arguments = ["slack", "poll"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                self?.loadReviews()
            }
        }
    }

    func retryReview(review: PRReview) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            task.arguments = ["review", review.prKey]
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                self.loadReviews()
            }
        }
    }

    func reReview(review: PRReview, extraPrompt: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            var args = ["re-review", review.prKey]
            let trimmed = extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                args += ["--prompt", trimmed]
            }
            task.arguments = args
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()

            DispatchQueue.main.async { [weak self] in
                self?.loadReviews()
            }
        }
    }

    func freshReview(review: PRReview, extraPrompt: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Discard existing session and worktree
            let discard = Process()
            discard.executableURL = URL(fileURLWithPath: self.prAgentBin)
            discard.arguments = ["discard", review.prKey]
            discard.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? discard.run()
            discard.waitUntilExit()

            // Write extra prompt into the (re-created) session dir before spawning review
            let sessionDir = self.sessionsDir.appendingPathComponent(review.prKey).path
            try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
            let trimmed = extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? trimmed.write(toFile: "\(sessionDir)/extra-prompt.txt", atomically: true, encoding: .utf8)
            }

            // Spawn fresh review using pr-agent-review directly with the saved fields
            let fresh = Process()
            fresh.executableURL = URL(fileURLWithPath: "\(self.prAgentDir)/bin/pr-agent-review")
            fresh.arguments = [
                review.prKey,
                review.prUrl,
                review.title,
                review.repo,
                String(review.prNumber),
                review.author,
                review.createdAt
            ]
            fresh.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? fresh.run()

            DispatchQueue.main.async { [weak self] in
                self?.loadReviews()
            }
        }
    }

    func discard(review: PRReview) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            task.arguments = ["discard", review.prKey]
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                self?.loadReviews()
            }
        }
    }

    func stopAutoMode(for review: PRReview) {
        // Kill the auto-monitor process if running
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Find and kill pr-agent-auto processes for this pr_key
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            task.arguments = ["-f", "pr-agent-auto \(review.prKey)"]
            try? task.run()
            task.waitUntilExit()

            DispatchQueue.main.async {
                self?.updateStatus(for: review, to: .ready)
            }
        }
    }

    func checkWebhookStatus() {
        let pidFile = prAgentHome.appendingPathComponent("webhook.pid")
        guard let pidString = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString) else {
            DispatchQueue.main.async { self.isWebhookRunning = false }
            return
        }
        let running = kill(pid, 0) == 0
        DispatchQueue.main.async { self.isWebhookRunning = running }
    }

    func startWebhook() {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            task.arguments = ["webhook", "start", "--daemon"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.checkWebhookStatus()
            }
        }
    }

    func stopWebhook() {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.prAgentBin)
            task.arguments = ["webhook", "stop"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.prAgentDir)
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                self.isWebhookRunning = false
            }
        }
    }

    private func updateStatus(for review: PRReview, to status: ReviewStatus) {
        let metaFile = sessionsDir
            .appendingPathComponent(review.prKey)
            .appendingPathComponent("meta.json")

        guard let data = try? Data(contentsOf: metaFile),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        json["status"] = status.rawValue
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }
        try? updated.write(to: metaFile)

        loadReviews()
    }
}
