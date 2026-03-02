#!/usr/bin/env bash
# Shared config/state helpers for pr-agent scripts
# Pure bash — no python yaml dependency

_config_value() {
    # Read a simple key: value from config.yaml (flat keys only)
    local key="$1" file="${CONFIG_FILE:-$HOME/.pr-agent/config.yaml}"
    # grep || true to avoid pipefail killing caller under set -eo pipefail
    (grep -E "^${key}:" "$file" 2>/dev/null || true) | sed "s/^${key}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//"
}

_config_list() {
    # Read a yaml list (lines starting with "  - ") under a key
    local key="$1" file="${CONFIG_FILE:-$HOME/.pr-agent/config.yaml}"
    sed -n "/^${key}:/,/^[^ ]/p" "$file" | grep '^[[:space:]]*-' | sed 's/^[[:space:]]*-[[:space:]]*//'
}

_config_multiline() {
    # Read a multiline value (block scalar after "key: |")
    local key="$1" file="${CONFIG_FILE:-$HOME/.pr-agent/config.yaml}"
    sed -n "/^${key}:/,/^[^ ]/p" "$file" | tail -n +2 | grep '^[[:space:]]' | sed 's/^  //'
}

_config_bool() {
    local key="$1" default="${2:-true}"
    local val
    val=$(_config_value "$key")
    val="${val:-$default}"
    case "$val" in
        true|yes|1|True|Yes) echo "true" ;;
        *) echo "false" ;;
    esac
}

_config_list_contains() {
    local key="$1" value="$2"
    _config_list "$key" | grep -qxF "$value" && echo "yes" || echo "no"
}

_mark_seen() {
    local pr_key="$1" file="${STATE_FILE:-$HOME/.pr-agent/state.json}"
    python3 -c "
import json
from datetime import datetime, timezone
with open('$file') as f:
    s = json.load(f)
s.setdefault('seen_prs', {})['$pr_key'] = datetime.now(timezone.utc).isoformat()
s['last_poll'] = datetime.now(timezone.utc).isoformat()
with open('$file', 'w') as f:
    json.dump(s, f, indent=2)
"
}

_update_meta_status() {
    local session_dir="$1" new_status="$2"
    python3 -c "
import json
with open('$session_dir/meta.json', 'r') as f:
    meta = json.load(f)
meta['status'] = '$new_status'
with open('$session_dir/meta.json', 'w') as f:
    json.dump(meta, f, indent=2)
"
}

_update_meta_field() {
    local session_dir="$1" field="$2" value="$3"
    # Pipe value through stdin to avoid single-quote injection in Python string
    printf '%s' "$value" | python3 -c "
import json, sys
val = sys.stdin.read()
with open('$session_dir/meta.json', 'r') as f:
    meta = json.load(f)
meta['$field'] = val
with open('$session_dir/meta.json', 'w') as f:
    json.dump(meta, f, indent=2)
"
}

_relative_time() {
    python3 -c "
from datetime import datetime, timezone
created = datetime.fromisoformat('$1')
now = datetime.now(timezone.utc)
delta = now - created
if delta.days > 0:
    print(f'{delta.days}d ago')
elif delta.seconds > 3600:
    print(f'{delta.seconds // 3600}h ago')
else:
    print(f'{delta.seconds // 60}m ago')
"
}

_meta_field() {
    local session_dir="$1" field="$2"
    python3 -c "import json; print(json.load(open('$session_dir/meta.json')).get('$field', ''))"
}

_config_repo_path() {
    local repo="$1" file="${CONFIG_FILE:-$HOME/.pr-agent/config.yaml}"
    sed -n "/^repos:/,/^[^ ]/p" "$file" | grep -E "^\s+${repo}:" | sed "s/^[[:space:]]*${repo}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | sed "s|^~|$HOME|"
}

_ide_cmd() {
    # Map IDE config name to the CLI command
    local ide
    ide=$(_config_value "ide")
    ide="${ide:-cursor}"
    case "$ide" in
        code|vscode)     echo "code" ;;
        cursor)          echo "cursor" ;;
        zed)             echo "zed" ;;
        idea|intellij)   echo "idea" ;;
        sublime|subl)    echo "subl" ;;
        vim|nvim)        echo "nvim" ;;
        *)               echo "$ide" ;;  # passthrough
    esac
}

_reviews_dir() {
    local dir
    dir=$(_config_value "reviews_dir")
    dir="${dir:-$HOME/pr-reviews}"
    # Expand ~
    dir="${dir/#\~/$HOME}"
    echo "$dir"
}

_notify() {
    local ntitle="$1" message="$2"
    osascript \
        -e "on run argv" \
        -e "display notification (item 2 of argv) with title (item 1 of argv)" \
        -e "end run" \
        -- "$ntitle" "$message" 2>/dev/null || true
}

_count_active_reviews() {
    local count=0 sessions_dir="${SESSIONS_DIR:-$HOME/.pr-agent/sessions}"
    for session_dir in "$sessions_dir"/*/; do
        [[ -f "$session_dir/meta.json" ]] || continue
        local status
        status=$(_meta_field "$session_dir" "status" 2>/dev/null || echo "")
        if [[ "$status" == "reviewing" ]]; then
            local pid
            pid=$(_meta_field "$session_dir" "pid" 2>/dev/null || echo "")
            if [[ -n "$pid" ]] && [[ "$pid" != "None" ]] && kill -0 "$pid" 2>/dev/null; then
                count=$((count + 1))
            fi
        fi
    done
    echo "$count"
}
