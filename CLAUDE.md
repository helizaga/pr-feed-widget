# PR Agent

Automated PR review system with macOS menu bar UI.

## Architecture

**Data flow**: `pr-agent poll` → GitHub API → `claude -p` (headless) → `~/.pr-agent/sessions/` → SwiftUI menu bar app → `claude --resume` (interactive)

### Components

- `bin/pr-agent` — CLI entrypoint (bash)
- `bin/pr-agent-poll` — GitHub poller, spawns review agents
- `bin/pr-agent-review` — Runs a single PR review via `claude -p`
- `ui/` — SwiftUI macOS menu bar app (reads sessions dir, launches agent on click)
- `config.yaml` — User configuration (installed to `~/.pr-agent/config.yaml`)

### Session directory structure

```
~/.pr-agent/sessions/<org>-<repo>-<pr-number>/
├── meta.json       # PR metadata, status, session ID, trigger source
├── review.md       # Claude's review output
└── comments.json   # Structured comments for posting
```

### Statuses

- `waiting-coderabbit` — Waiting for CodeRabbit review before starting
- `reviewing` — Claude agent is running
- `ready` — Review complete, awaiting human
- `in-progress` — Human is engaging with agent
- `posted` — Comments posted to PR
- `dismissed` — Human chose not to review
- `failed` — Review agent errored
- `merged` — PR was merged
- `auto-monitoring` — Auto-mode: watching for new comments
- `auto-responding` — Auto-mode: responding to a comment

## Build

```bash
# CLI only
./install.sh

# Menu bar app
cd ui && swift build -c release
```

## Do not

- Run `pr-agent poll` in foreground unless testing — use `pr-agent start` for launchd
- Modify state.json by hand — use `pr-agent` CLI commands
