import SwiftUI
import AppKit

class ReReviewController {
    static let shared = ReReviewController()
    private var window: NSWindow?

    func show(review: PRReview, store: PRReviewStore) {
        window?.close()

        let view = ReReviewContent(review: review, store: store, onClose: { [weak self] in
            self?.window?.close()
            self?.window = nil
        })

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 280)

        let w = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.title = "Re-review \(review.displayName)"
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

private struct ReReviewContent: View {
    let review: PRReview
    @ObservedObject var store: PRReviewStore
    let onClose: () -> Void
    @State private var extraPrompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add focus instructions for this review. This is prepended to the default prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $extraPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            HStack(spacing: 8) {
                ForEach(["Security", "Performance", "Types"], id: \.self) { tag in
                    Button(tag) {
                        if extraPrompt.isEmpty {
                            extraPrompt = "Focus on \(tag.lowercased()) concerns."
                        } else {
                            extraPrompt += " Focus on \(tag.lowercased()) concerns."
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
                }
                Spacer()
            }

            HStack {
                Button("Start Fresh") {
                    store.freshReview(review: review, extraPrompt: extraPrompt)
                    onClose()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)

                Spacer()

                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Re-review") {
                    store.reReview(review: review, extraPrompt: extraPrompt)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 220)
    }
}
