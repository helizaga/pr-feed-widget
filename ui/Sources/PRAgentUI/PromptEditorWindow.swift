import SwiftUI
import AppKit
import Yams

class PromptEditorController {
    static let shared = PromptEditorController()
    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PromptEditorContent(onClose: { [weak self] in
            self?.window?.close()
            self?.window = nil
        })

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 680, height: 560)

        let w = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.title = "Review Prompt"
        w.contentView = hostingView
        w.isFloatingPanel = true
        w.becomesKeyOnlyIfNeeded = false
        w.level = .floating
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }
}

private let defaultPrompt = """
You are reviewing a pull request. Here are the details:

- **PR**: {{repo}}#{{pr_num}}
- **Title**: {{title}}
- **Author**: {{author}}
- **URL**: {{pr_url}}

{{extra_instructions}}

Review this PR thoroughly. Tell me any comments and any blockers.
Don't comment about lack of unit tests unless it's egregious.
Be direct and focus on what matters.

After your review, output a structured summary with:
1. **Overview**: What this PR does in 2-3 sentences
2. **Key Changes**: Bullet list of the important changes
3. **Comments**: Specific comments you'd suggest posting on the PR, each with:
   - File path and line number (if applicable)
   - The comment text
   - Severity: blocker, suggestion, nit
4. **Verdict**: approve, request-changes, or comment-only

Use the GitHub CLI (gh) to fetch the PR diff and details. The command is:
  gh pr view {{pr_url}} --json title,body,files,additions,deletions,commits
  gh pr diff {{pr_url}}

You have full access to the codebase in the current directory. As you review the diff, also explore the surrounding code for context:
- Read the full files being changed, not just the diff hunks — understand the architecture around the changes
- Grep for similar patterns, related function names, and existing conventions to check if the PR is consistent with the rest of the repo
- Trace function calls, check types, and see how the changed code is used elsewhere
- Look at related tests and how similar features are tested
- If the PR introduces a pattern that differs from existing conventions, flag it — unless the old pattern is clearly worse

Don't just review the diff in isolation. A change that looks fine in the diff can still be wrong if it breaks conventions, duplicates existing utilities, or misunderstands the surrounding architecture.

Also check existing comments and review threads on the PR:
  gh api repos/{{repo_full}}/issues/{{pr_num}}/comments --jq '.[] | {user: .user.login, body: .body}'
  gh api repos/{{repo_full}}/pulls/{{pr_num}}/reviews --jq '.[] | {user: .user.login, state: .state, body: .body}'
Consider what reviewers and bots (especially CodeRabbit) have already pointed out. Don't repeat their comments — instead, build on them, disagree where warranted, or flag things they missed. If someone requested changes, check whether those have been addressed.

Use any available MCP tools and integrations to gather organizational context around this PR. For example:
- Search Notion for related design docs, RFCs, or specs that describe what this feature should do
- Check Linear for the linked issue or project to understand requirements and acceptance criteria
- Search Slack for recent discussions about this feature or area of the codebase
Use whatever tools are available to you — the goal is to understand the intent and context behind the PR, not just the code. If a tool isn't available or returns nothing useful, move on — don't block on it.

Start by fetching the PR details, diff, and comments, then review thoroughly — exploring the codebase and organizational context as needed.
"""

private struct PromptEditorContent: View {
    let onClose: () -> Void
    @State private var prompt: String = ""
    @State private var savedIndicator = false

    private let configPath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.pr-agent/config.yaml"
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Full prompt template sent to Claude for every review. Use {{repo}}, {{pr_num}}, {{title}}, {{author}}, {{pr_url}}, and {{extra_instructions}} as placeholders.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $prompt)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            HStack {
                Button("Reset to Default") {
                    prompt = defaultPrompt
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)

                Spacer()

                if savedIndicator {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    savePrompt()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { loadPrompt() }
    }

    private func loadPrompt() {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8),
              let yaml = try? Yams.load(yaml: content) as? [String: Any],
              let p = yaml["review_prompt"] as? String else {
            return
        }
        prompt = p.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func savePrompt() {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        let indentedPrompt = prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")

        // Match "review_prompt: |" then all following lines that are either
        // indented or completely blank, stopping at the next top-level key or EOF.
        // Uses multiline mode so ^ matches line starts.
        let pattern = #"(?m)^review_prompt:\s*\|[^\n]*\n((?:[ \t]+[^\n]*|[ \t]*)\n)*"#
        let replacement = "review_prompt: |\n\(indentedPrompt)\n"

        if let range = content.range(of: pattern, options: .regularExpression) {
            content.replaceSubrange(range, with: replacement)
        } else {
            content += "\nreview_prompt: |\n\(indentedPrompt)\n"
        }

        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)

        withAnimation {
            savedIndicator = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { savedIndicator = false }
        }
    }
}
