#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$BIN_DIR"

# Make scripts executable
chmod +x "$SCRIPT_DIR/bin/pr-agent"
chmod +x "$SCRIPT_DIR/bin/pr-agent-poll"
chmod +x "$SCRIPT_DIR/bin/pr-agent-review"
chmod +x "$SCRIPT_DIR/bin/pr-agent-webhook"
chmod +x "$SCRIPT_DIR/bin/pr-agent-slack"
chmod +x "$SCRIPT_DIR/bin/pr-agent-slack-review"
chmod +x "$SCRIPT_DIR/bin/pr-agent-auto"

# Symlink pr-agent to PATH
ln -sf "$SCRIPT_DIR/bin/pr-agent" "$BIN_DIR/pr-agent"

# Initialize config
"$SCRIPT_DIR/bin/pr-agent" status >/dev/null 2>&1

# Build and relaunch menu bar app
echo "Building menu bar app..."
bash "$SCRIPT_DIR/ui/build-app.sh"

pkill -f "PRAgentUI" 2>/dev/null || true
sleep 0.5

# Clear quarantine/provenance attributes so macOS doesn't block the app.
xattr -cr "$SCRIPT_DIR/ui/build/PR Agent.app" 2>/dev/null || true

# Launch the binary directly — `open` goes through Launch Services which
# suspends ad-hoc signed apps (Gatekeeper rejects them). Backgrounding
# with & keeps it connected to the GUI session so MenuBarExtra works.
"$SCRIPT_DIR/ui/build/PR Agent.app/Contents/MacOS/PRAgentUI" </dev/null &>/dev/null &
disown

echo ""
echo "PR Agent installed and relaunched."
