import SwiftUI

struct PRMenuView: View {
    @ObservedObject var store: PRReviewStore
    @FocusState private var isSearchFocused: Bool
    @State private var showReviewRequested: Bool = false
    @State private var showMerged: Bool = false
    @State private var eventMonitor: Any?
    // prompt editor opens as standalone NSPanel, not state-driven

    /// Whether the current search query looks like a PR reference (URL, #1234, repo#1234)
    private var queryIsReviewRef: Bool {
        let q = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return false }
        if q.hasPrefix("http://") || q.hasPrefix("https://") { return true }
        // Match #<digits> or word#<digits> (e.g. #1234, repo#42) — not arbitrary # in text
        if q.range(of: #"(^|[a-zA-Z0-9_-])#\d+"#, options: .regularExpression) != nil { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("PR Reviews")
                    .font(.headline)
                Spacer()
                if store.isWebhookRunning {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Webhook server active")
                }
                if !store.waitingReviews.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("\(store.waitingReviews.count) waiting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !store.reviewingReviews.isEmpty {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("\(store.reviewingReviews.count) reviewing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Unified search + review request bar
            HStack(spacing: 6) {
                Image(systemName: queryIsReviewRef ? "plus.circle" : "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(queryIsReviewRef ? .blue : .secondary.opacity(0.5))
                TextField("Search or review: #1234, repo#1234, URL", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if queryIsReviewRef {
                            submitReviewRequest()
                        }
                    }
                if showReviewRequested {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if !store.searchQuery.isEmpty && !showReviewRequested {
                    Button(action: { store.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            // Hint when query looks like a review request
            if queryIsReviewRef && !showReviewRequested {
                Text("Press Return to start review")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            if store.reviews.isEmpty && store.isPolling {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Polling for PRs...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if store.reviews.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No PR reviews")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if store.activeReviews.isEmpty && store.mergedReviews.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Active PRs
                        ForEach(store.activeReviews) { review in
                            PRRowView(review: review, store: store)
                                .opacity(review.status == .posted || review.status == .dismissed || review.status == .failed ? 0.6 : 1.0)
                        }

                        // Merged section (collapsible)
                        if !store.mergedReviews.isEmpty {
                            Divider()
                                .padding(.vertical, 4)

                            Button(action: { showMerged.toggle() }) {
                                HStack {
                                    Image(systemName: showMerged ? "chevron.down" : "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 12)
                                    Text("Merged")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("(\(store.mergedReviews.count))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)

                            if showMerged {
                                ForEach(store.mergedReviews) { review in
                                    PRRowView(review: review, store: store)
                                        .opacity(0.5)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 500)
            }

            Divider()

            // Footer actions
            HStack {
                if store.isPolling {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Polling...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(action: { runPoll() }) {
                        Label("Poll Now", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Menu {
                    Button("Poll Slack") {
                        store.runSlackPoll()
                    }
                    Divider()
                    Button("Reset & Re-poll") {
                        store.discardAndRepoll()
                    }
                    Button("Discard All Reviews") {
                        store.discardAll()
                    }
                    Divider()
                    Section("Webhook") {
                        if store.isWebhookRunning {
                            Button("Stop Webhook Server") {
                                store.stopWebhook()
                            }
                        } else {
                            Button("Start Webhook Server") {
                                store.startWebhook()
                            }
                        }
                    }
                    Divider()
                    Button("Settings...") {
                        SettingsController.shared.show()
                    }
                    Button("Edit Review Prompt...") {
                        PromptEditorController.shared.show()
                    }
                    Menu("IDE") {
                        ForEach(store.editorManager.installedEditors) { editor in
                            Button {
                                store.editorManager.selectEditor(editor.id)
                            } label: {
                                if store.editorManager.selectedEditorId == editor.id {
                                    Label(editor.displayName, systemImage: "checkmark")
                                } else {
                                    Text(editor.displayName)
                                }
                            }
                        }
                        if !store.editorManager.installedEditors.isEmpty {
                            Divider()
                        }
                        Button("Custom Command...") {
                            promptCustomEditor()
                        }
                        Divider()
                        Button {
                            store.editorManager.selectEditor(nil)
                        } label: {
                            if store.editorManager.selectedEditorId == nil {
                                Label("None", systemImage: "checkmark")
                            } else {
                                Text("None")
                            }
                        }
                    }
                    Button("View in Terminal") {
                        openAllInTerminal()
                    }
                    Divider()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "gear")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            // MenuBarExtra(.window) uses an NSPanel that doesn't become key by default,
            // so keyboard events don't reach SwiftUI. Force it to accept key input.
            DispatchQueue.main.async {
                if let panel = NSApp.windows.first(where: { $0 is NSPanel }) as? NSPanel {
                    panel.becomesKeyOnlyIfNeeded = false
                    panel.makeKey()
                }
                isSearchFocused = true
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers == "f" {
                    isSearchFocused = true
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }

    private func submitReviewRequest() {
        let ref = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return }
        store.requestReview(ref: ref)
        store.searchQuery = ""
        showReviewRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showReviewRequested = false
        }
    }

    private func runPoll() {
        store.runPoll()
    }

    private func promptCustomEditor() {
        let alert = NSAlert()
        alert.messageText = "Custom IDE Command"
        alert.informativeText = "Enter the CLI command to open a directory (e.g., subl, mate, micro):"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "command-name"
        if let current = store.editorManager.selectedEditorId,
           EditorManager.registry.first(where: { $0.id == current }) == nil {
            input.stringValue = current
        }
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let value = input.stringValue.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                store.editorManager.selectEditor(value)
            }
        }
    }

    private func openAllInTerminal() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let scriptPath = NSTemporaryDirectory() + "pr-agent-list.command"
        let script = "#!/bin/bash\nexport TERM=\"${TERM:-xterm-256color}\"\ntput reset 2>/dev/null\nexec \"\(home)/.local/bin/pr-agent\" list\n"

        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", scriptPath]
        try? chmod.run()
        chmod.waitUntilExit()

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if FileManager.default.fileExists(atPath: "/Applications/iTerm.app") {
            open.arguments = ["-a", "iTerm", scriptPath]
        } else {
            open.arguments = [scriptPath]
        }
        try? open.run()
    }
}

struct PRRowView: View {
    let review: PRReview
    @ObservedObject var store: PRReviewStore
    @State private var isHovering = false
    // re-review opens as standalone NSPanel, not state-driven

    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            Image(systemName: review.status.icon)
                .foregroundStyle(review.status.color)
                .font(.caption)
                .frame(width: 16)

            // PR info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(review.displayName)
                        .font(.caption)
                        .fontWeight(.semibold)

                    if review.isSlackTriggered {
                        Image(systemName: "number")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }

                    if review.isAutoMode {
                        Image(systemName: "gearshape.2")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }

                    if review.isHighPriority {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Text(review.relativeAge)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(review.shortTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(review.author)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text("\u{00b7}")
                        .foregroundStyle(.tertiary)

                    Text(review.status.label)
                        .font(.caption2)
                        .foregroundStyle(review.status.color)

                    if review.effectiveBackend != "claude" {
                        Text("\u{00b7}")
                            .foregroundStyle(.tertiary)

                        Text(review.effectiveBackend)
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            handleTap()
        }
        .contextMenu {
            if review.status == .ready || review.status == .inProgress || review.status == .reviewing {
                if review.isResumable {
                    Button("Open Agent Session") {
                        store.openSession(for: review)
                    }
                } else {
                    Button("Open Agent Session (new)") {
                        store.openSession(for: review)
                    }
                }
            }

            if review.reviewClone != nil {
                Button("Open in IDE") {
                    store.openInIDE(review)
                }
            }

            Button("View on GitHub") {
                store.openInGitHub(for: review)
            }

            if review.isAutoMode && (review.status == .autoMonitoring || review.status == .autoResponding) {
                Button("Stop Auto-Mode") {
                    store.stopAutoMode(for: review)
                }
            }

            if review.status == .failed {
                Button("Retry Review") {
                    store.retryReview(review: review)
                }
            }

            if review.status != .dismissed && review.status != .posted {
                Divider()
                Button("Dismiss") {
                    store.dismiss(review: review)
                }
            }

            Button("Re-review...") {
                ReReviewController.shared.show(review: review, store: store)
            }

            Divider()
            Button("Discard", role: .destructive) {
                store.discard(review: review)
            }
        }
    }

    private func handleTap() {
        switch review.status {
        case .ready, .inProgress, .reviewing:
            store.openSession(for: review)
        default:
            store.openInGitHub(for: review)
        }
    }
}
