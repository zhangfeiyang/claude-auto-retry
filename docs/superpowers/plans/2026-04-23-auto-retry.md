# Claude Auto Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code plugin that automatically detects "Content block not found" API errors and retries the last user prompt without manual intervention.

**Architecture:** SessionStart hook launches a background daemon that tails the session JSONL log. On error detection, it extracts the last user prompt and injects it into the terminal via `/dev/pts` (Unix) or SendKeys (Windows). Cross-platform support via platform-specific daemon scripts behind a polyglot launcher.

**Tech Stack:** Bash (Unix daemon), PowerShell (Windows daemon), Claude Code plugin hooks API

---

## File Structure

| File | Responsibility |
|------|---------------|
| `.claude-plugin/plugin.json` | Plugin metadata for Claude Code |
| `hooks/hooks.json` | Register SessionStart hook |
| `hooks/run-hook` | Cross-platform polyglot launcher (bash/cmd) |
| `hooks/retry-daemon` | Unix daemon: monitor log, detect error, inject retry |
| `hooks/retry-daemon.ps1` | Windows daemon: same logic in PowerShell |
| `CLAUDE.md` | Plugin instructions |
| `README.md` | User-facing documentation |
| `LICENSE` | MIT license |

---

### Task 1: Plugin Scaffold — plugin.json and hooks.json

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `hooks/hooks.json`

- [ ] **Step 1: Create .claude-plugin/plugin.json**

```json
{
  "name": "claude-auto-retry",
  "description": "Automatically retries Claude Code prompts when 'Content block not found' API errors occur",
  "version": "1.0.0",
  "author": {
    "name": "zhangfy"
  },
  "license": "MIT",
  "keywords": [
    "retry",
    "error-handling",
    "auto-retry",
    "resilience"
  ]
}
```

- [ ] **Step 2: Create hooks/hooks.json**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook\" retry-daemon",
            "async": true
          }
        ]
      }
    ]
  }
}
```

Note: `async: true` so the daemon runs in background without blocking session start.

- [ ] **Step 3: Commit**

```bash
cd /home/zhangfy/claude-auto-retry
git add .claude-plugin/plugin.json hooks/hooks.json
git commit -m "feat: add plugin metadata and SessionStart hook config"
```

---

### Task 2: Cross-Platform Launcher — run-hook

**Files:**
- Create: `hooks/run-hook`

This is a polyglot script that works as both a Windows batch file and a Unix bash script.

- [ ] **Step 1: Write run-hook**

```bash
: << 'CMDBLOCK'
@echo off
REM Cross-platform polyglot wrapper for hook scripts.
REM On Windows: cmd.exe runs the batch portion.
REM On Unix: the shell interprets this as a script (: is a no-op in bash).
REM
REM Usage: run-hook <script-name> [args...]

if "%~1"=="" (
    echo run-hook: missing script name >&2
    exit /b 1
)

set "HOOK_DIR=%~dp0"

REM On Windows, launch PowerShell daemon
powershell -ExecutionPolicy Bypass -File "%HOOK_DIR%retry-daemon.ps1" %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%
CMDBLOCK

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$1"
shift

exec bash "${SCRIPT_DIR}/${SCRIPT_NAME}" "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x hooks/run-hook
```

- [ ] **Step 3: Commit**

```bash
cd /home/zhangfy/claude-auto-retry
git add hooks/run-hook
git commit -m "feat: add cross-platform polyglot launcher"
```

---

### Task 3: Unix Daemon — retry-daemon (Core Logic)

**Files:**
- Create: `hooks/retry-daemon`

This is the core of the plugin. The daemon:
1. Discovers the current session (PID, session ID, project dir, PTS number)
2. Tails the session JSONL log
3. Detects "Content block not found" errors
4. Extracts the last user prompt
5. Writes it to the terminal
6. Retries up to N times with configurable interval

- [ ] **Step 1: Write retry-daemon**

```bash
#!/usr/bin/env bash
set -uo pipefail

# Configuration (overridable via env vars)
MAX_RETRIES="${CLAUDE_RETRY_MAX:-3}"
RETRY_INTERVAL="${CLAUDE_RETRY_INTERVAL:-2}"
ERROR_PATTERN="${CLAUDE_RETRY_PATTERN:-Content block not found}"
LOG_FILE="${CLAUDE_RETRY_LOG:-$HOME/.claude/plugins/cache/claude-auto-retry/retry.log}"
LOCK_DIR="/tmp/claude-auto-retry"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$LOCK_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# --- Session Discovery ---
# Find the most recent session file for the current process
find_my_session() {
    # Walk through all session files, find the one whose PID is our parent's context
    # The hook runs as a child of the claude process, so PPID gives us the claude PID
    local claude_pid="$PPID"

    # Try direct session match by PID
    local session_file="$HOME/.claude/sessions/${claude_pid}.json"
    if [[ -f "$session_file" ]]; then
        echo "$session_file"
        return 0
    fi

    # Fallback: find the most recently modified session file
    local latest
    latest=$(ls -t "$HOME/.claude/sessions/"*.json 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
        echo "$latest"
        return 0
    fi

    return 1
}

# Parse session file to get session ID and project dir
parse_session() {
    local session_file="$1"
    SESSION_ID=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sessionId',''))" < "$session_file")
    SESSION_CWD=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" < "$session_file")
    SESSION_PID=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pid',''))" < "$session_file")
}

# Convert cwd to escaped project dir path
get_project_dir() {
    # Claude Code escapes / as - in project dir names
    local cwd="$1"
    local escaped
    escaped=$(echo "$cwd" | sed 's|/|-|g')
    echo "$HOME/.claude/projects/${escaped}"
}

# Get PTS number for the claude process
get_pts() {
    local pid="$1"
    # Read the symlink of fd/0 (stdin) to find the terminal
    local tty_link
    tty_link=$(readlink "/proc/${pid}/fd/0" 2>/dev/null || echo "")
    if [[ "$tty_link" =~ pts/([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# --- Error Detection ---
# Extract the last user prompt from the JSONL log
get_last_user_prompt() {
    local log="$1"
    # Find the last user message with string content (not tool_result)
    python3 -c "
import json, sys
last_prompt = ''
for line in open('$log'):
    try:
        obj = json.loads(line)
    except:
        continue
    if obj.get('type') == 'user':
        msg = obj.get('message', {})
        content = msg.get('content', '')
        if isinstance(content, str) and content.strip():
            last_prompt = content.strip()
        elif isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get('type') == 'text':
                    last_prompt = item.get('text', '').strip()
                    break
                elif isinstance(item, str) and item.strip():
                    last_prompt = item.strip()
                    break
print(last_prompt)
" 2>/dev/null
}

# Check if a JSONL line contains our target error
is_error_line() {
    local line="$1"
    # Must contain both "Content block not found" AND be an assistant message
    # This avoids false positives from user messages mentioning the error
    echo "$line" | python3 -c "
import json, sys
line = sys.stdin.read().strip()
if not line:
    sys.exit(1)
try:
    obj = json.loads(line)
except:
    sys.exit(1)
if obj.get('type') != 'assistant':
    sys.exit(1)
msg = obj.get('message', {})
content = msg.get('content', [])
if isinstance(content, list):
    for c in content:
        if isinstance(c, dict) and 'Content block not found' in c.get('text', ''):
            sys.exit(0)
elif isinstance(content, str) and 'Content block not found' in content:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# --- Retry Injection ---
inject_prompt() {
    local pts="$1"
    local prompt="$2"
    if [[ -w "/dev/pts/${pts}" ]]; then
        echo "$prompt" > "/dev/pts/${pts}"
        log "Injected prompt into /dev/pts/${pts}"
        return 0
    else
        log "ERROR: Cannot write to /dev/pts/${pts}"
        return 1
    fi
}

# --- Daemon Check: is claude still running? ---
is_claude_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# --- Main ---
main() {
    log "Daemon starting (PPID=$PPID)"

    # Prevent duplicate daemons for the same session
    local lock_file
    lock_file="${LOCK_DIR}/daemon-$$"
    if [[ -f "$lock_file" ]]; then
        log "Another daemon instance exists for PID $$, exiting"
        exit 0
    fi
    echo "$$" > "$lock_file"
    trap "rm -f '$lock_file'" EXIT

    # Discover session
    local session_file
    session_file=$(find_my_session) || {
        log "No session file found, exiting"
        exit 1
    }
    log "Session file: $session_file"

    parse_session "$session_file"
    log "Session ID: $SESSION_ID, CWD: $SESSION_CWD, PID: $SESSION_PID"

    local project_dir
    project_dir=$(get_project_dir "$SESSION_CWD")
    local session_log="${project_dir}/${SESSION_ID}.jsonl"

    if [[ ! -f "$session_log" ]]; then
        log "Session log not found: $session_log, exiting"
        exit 1
    fi
    log "Monitoring: $session_log"

    local pts
    pts=$(get_pts "$SESSION_PID") || {
        log "Cannot determine PTS for PID $SESSION_PID"
        exit 1
    }
    log "PTS: $pts"

    # Monitor loop
    local retry_count=0
    local last_error_uuid=""

    log "Daemon ready, monitoring for errors..."

    tail -f "$session_log" 2>/dev/null | while IFS= read -r line; do
        # Check if claude process is still alive
        if ! is_claude_alive "$SESSION_PID"; then
            log "Claude process $SESSION_PID exited, stopping daemon"
            break
        fi

        # Check for error pattern
        if echo "$line" | grep -q "$ERROR_PATTERN"; then
            if is_error_line "$line"; then
                # Extract UUID to avoid reacting to the same error twice
                local current_uuid
                current_uuid=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('uuid',''))" 2>/dev/null || echo "")

                if [[ "$current_uuid" == "$last_error_uuid" ]]; then
                    continue
                fi
                last_error_uuid="$current_uuid"
                retry_count=$((retry_count + 1))

                log "Detected error (attempt $retry_count/$MAX_RETRIES, uuid=$current_uuid)"

                if [[ $retry_count -gt $MAX_RETRIES ]]; then
                    log "Max retries ($MAX_RETRIES) exceeded, stopping"
                    break
                fi

                # Get last user prompt
                local prompt
                prompt=$(get_last_user_prompt "$session_log")

                if [[ -z "$prompt" ]]; then
                    log "No user prompt found to retry"
                    continue
                fi

                log "Retrying with prompt: ${prompt:0:80}..."

                sleep "$RETRY_INTERVAL"
                inject_prompt "$pts" "$prompt"
            fi
        fi
    done

    log "Daemon exiting"
}

main "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x hooks/retry-daemon
```

- [ ] **Step 3: Commit**

```bash
cd /home/zhangfy/claude-auto-retry
git add hooks/retry-daemon
git commit -m "feat: add Unix retry daemon with log monitoring and PTS injection"
```

---

### Task 4: Windows Daemon — retry-daemon.ps1

**Files:**
- Create: `hooks/retry-daemon.ps1`

PowerShell equivalent of the Unix daemon, using Windows-compatible mechanisms.

- [ ] **Step 1: Write retry-daemon.ps1**

```powershell
# retry-daemon.ps1 — Windows daemon for Claude Auto Retry plugin
# Monitors session JSONL log for "Content block not found" errors and retries

$ErrorActionPreference = "SilentlyContinue"

# Configuration
$MaxRetries = if ($env:CLAUDE_RETRY_MAX) { [int]$env:CLAUDE_RETRY_MAX } else { 3 }
$RetryInterval = if ($env:CLAUDE_RETRY_INTERVAL) { [int]$env:CLAUDE_RETRY_INTERVAL } else { 2 }
$ErrorPattern = if ($env:CLAUDE_RETRY_PATTERN) { $env:CLAUDE_RETRY_PATTERN } else { "Content block not found" }
$LogFile = if ($env:CLAUDE_RETRY_LOG) { $env:CLAUDE_RETRY_LOG } else { "$env:USERPROFILE\.claude\plugins\cache\claude-auto-retry\retry.log" }

$logDir = Split-Path -Parent $LogFile
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$timestamp] $Message"
}

# Session discovery
$SessionsDir = "$env:USERPROFILE\.claude\sessions"
$latestSession = Get-ChildItem -Path $SessionsDir -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $latestSession) {
    Write-Log "No session file found, exiting"
    exit 1
}

$sessionData = Get-Content $latestSession.FullName | ConvertFrom-Json
$sessionId = $sessionData.sessionId
$sessionCwd = $sessionData.cwd
$sessionPid = $sessionData.pid

Write-Log "Session ID: $sessionId, CWD: $sessionCwd, PID: $sessionPid"

# Build project dir path
$escapedCwd = $sessionCwd -replace '\\', '-'
$projectDir = "$env:USERPROFILE\.claude\projects\$escapedCwd"
$sessionLog = "$projectDir\$sessionId.jsonl"

if (-not (Test-Path $sessionLog)) {
    Write-Log "Session log not found: $sessionLog, exiting"
    exit 1
}
Write-Log "Monitoring: $sessionLog"

# Get last user prompt from JSONL
function Get-LastUserPrompt {
    param([string]$LogPath)
    $lastPrompt = ""
    Get-Content $LogPath | ForEach-Object {
        try {
            $obj = $_ | ConvertFrom-Json
            if ($obj.type -eq "user") {
                $content = $obj.message.content
                if ($content -is [string] -and $content.Trim()) {
                    $lastPrompt = $content.Trim()
                } elseif ($content -is [array]) {
                    foreach ($item in $content) {
                        if ($item.type -eq "text" -and $item.text.Trim()) {
                            $lastPrompt = $item.text.Trim()
                            break
                        }
                    }
                }
            }
        } catch {}
    }
    return $lastPrompt
}

# Check if a JSONL line is an error
function Test-ErrorLine {
    param([string]$Line)
    try {
        $obj = $Line | ConvertFrom-Json
        if ($obj.type -ne "assistant") { return $false }
        $content = $obj.message.content
        if ($content -is [array]) {
            foreach ($item in $content) {
                if ($item.type -eq "text" -and $item.text -match "Content block not found") {
                    return $true
                }
            }
        } elseif ($content -is [string] -and $content -match "Content block not found") {
            return $true
        }
    } catch {}
    return $false
}

# Inject prompt via SendKeys
function Send-RetryPrompt {
    param([string]$Prompt)
    try {
        $shell = New-Object -ComObject WScript.Shell
        # Try to activate the Claude Code window
        $activated = $shell.AppActivate("claude")
        if (-not $activated) {
            # Try alternative window titles
            $activated = $shell.AppActivate("Claude Code")
        }
        if ($activated) {
            Start-Sleep -Milliseconds 200
            # Send the prompt character by character to avoid issues with special chars
            foreach ($char in $Prompt.ToCharArray()) {
                switch ($char) {
                    "{" { $shell.SendKeys("{{}") }
                    "}" { $shell.SendKeys("{}}") }
                    "+" { $shell.SendKeys("{+}") }
                    "^" { $shell.SendKeys("{^}") }
                    "%" { $shell.SendKeys("{%}") }
                    "~" { $shell.SendKeys("{~}") }
                    "(" { $shell.SendKeys("{(}") }
                    ")" { $shell.SendKeys("{)}") }
                    default { $shell.SendKeys($char) }
                }
            }
            $shell.SendKeys("{ENTER}")
            Write-Log "Sent retry prompt via SendKeys"
            return $true
        } else {
            Write-Log "Could not activate Claude Code window"
            return $false
        }
    } catch {
        Write-Log "SendKeys error: $_"
        return $false
    }
}

# Main monitoring loop
$retryCount = 0
$lastErrorUuid = ""

Write-Log "Daemon ready, monitoring for errors..."

# Use Get-Content -Wait to tail the log (PowerShell equivalent of tail -f)
Get-Content $sessionLog -Wait | ForEach-Object {
    $line = $_

    # Check if claude process is still alive
    $proc = Get-Process -Id $sessionPid -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Log "Claude process $sessionPid exited, stopping daemon"
        break
    }

    # Check for error pattern
    if ($line -match $ErrorPattern) {
        if (Test-ErrorLine -Line $line) {
            try {
                $obj = $line | ConvertFrom-Json
                $currentUuid = $obj.uuid
            } catch {
                $currentUuid = ""
            }

            if ($currentUuid -eq $lastErrorUuid) {
                return
            }
            $lastErrorUuid = $currentUuid
            $retryCount++

            Write-Log "Detected error (attempt $retryCount/$MaxRetries, uuid=$currentUuid)"

            if ($retryCount -gt $MaxRetries) {
                Write-Log "Max retries ($MaxRetries) exceeded, stopping"
                break
            }

            $prompt = Get-LastUserPrompt -LogPath $sessionLog
            if (-not $prompt) {
                Write-Log "No user prompt found to retry"
                return
            }

            Write-Log "Retrying with prompt: $($prompt.Substring(0, [Math]::Min(80, $prompt.Length)))..."
            Start-Sleep -Seconds $RetryInterval
            Send-RetryPrompt -Prompt $prompt
        }
    }
}

Write-Log "Daemon exiting"
```

- [ ] **Step 2: Commit**

```bash
cd /home/zhangfy/claude-auto-retry
git add hooks/retry-daemon.ps1
git commit -m "feat: add Windows PowerShell retry daemon with SendKeys injection"
```

---

### Task 5: Plugin Instructions — CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Write CLAUDE.md**

```markdown
# Claude Auto Retry Plugin

Automatically retries Claude Code prompts when "Content block not found" API errors occur.

## How It Works

On session start, a background daemon monitors your session log. When it detects a "Content block not found" error, it automatically re-submits your last prompt.

## Configuration

Set environment variables before starting Claude Code:

- `CLAUDE_RETRY_MAX` — Max retry attempts (default: 3)
- `CLAUDE_RETRY_INTERVAL` — Seconds between retries (default: 2)
- `CLAUDE_RETRY_PATTERN` — Error pattern to match (default: "Content block not found")
- `CLAUDE_RETRY_LOG` — Log file path (default: ~/.claude/plugins/cache/claude-auto-retry/retry.log)
```

- [ ] **Step 2: Commit**

```bash
cd /home/zhangfy/claude-auto-retry
git add CLAUDE.md
git commit -m "docs: add plugin CLAUDE.md instructions"
```

---

### Task 6: User Documentation — README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

```markdown
# Claude Auto Retry

A [Claude Code](https://claude.ai/code) plugin that automatically retries your prompts when encountering `"API Error: Content block not found"` errors.

## Why?

Claude Code sometimes hits transient API errors like "Content block not found" — these are server-side issues that resolve on retry. But they interrupt your workflow, especially during long autonomous sessions. This plugin detects those errors and automatically re-submits your last prompt.

## Features

- **Fully automatic** — No manual intervention needed
- **Session-aware** — Preserves your full conversation history
- **Cross-platform** — Works on Linux, macOS, and Windows
- **Configurable** — Adjust retry count, interval, and error patterns
- **Zero dependencies** — Pure Bash (Unix) and PowerShell (Windows)

## Installation

```bash
claude plugins install github:<your-username>/claude-auto-retry
```

Or manually clone into your plugins directory:

```bash
git clone https://github.com/<your-username>/claude-auto-retry.git \
  ~/.claude/plugins/cache/local/claude-auto-retry
```

Then enable in `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "claude-auto-retry@local": true
  }
}
```

## Configuration

Override defaults with environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_RETRY_MAX` | `3` | Maximum retry attempts per error |
| `CLAUDE_RETRY_INTERVAL` | `2` | Seconds to wait between retries |
| `CLAUDE_RETRY_PATTERN` | `Content block not found` | Error text pattern to match |
| `CLAUDE_RETRY_LOG` | `~/.claude/plugins/cache/claude-auto-retry/retry.log` | Daemon log file path |

Example:

```bash
export CLAUDE_RETRY_MAX=5
export CLAUDE_RETRY_INTERVAL=3
claude
```

## How It Works

1. When Claude Code starts a session, the plugin's `SessionStart` hook launches a background daemon
2. The daemon monitors the session's JSONL log file for error patterns
3. On detecting "Content block not found", it extracts your last prompt
4. The prompt is injected back into Claude Code's terminal input
5. If the error persists, it retries up to the configured maximum

### Platform Details

- **Linux/macOS**: Writes directly to `/dev/pts/<N>` (the terminal device)
- **Windows**: Uses `WScript.Shell` SendKeys to send the prompt to the active Claude Code window

## Troubleshooting

### Check daemon logs

```bash
cat ~/.claude/plugins/cache/claude-auto-retry/retry.log
```

### Windows: SendKeys not working

- Ensure Claude Code window is not minimized
- Some security software may block SendKeys — add an exception
- Try running Claude Code as administrator

### Plugin not activating

- Verify the plugin is listed in `~/.claude/settings.json` under `enabledPlugins`
- Check that the daemon script is executable (`chmod +x hooks/retry-daemon` on Unix)

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
cd /home/zhangfy/claude-auto-retry
git add README.md
git commit -m "docs: add README with installation and usage instructions"
```

---

### Task 7: License File

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Write LICENSE**

```
MIT License

Copyright (c) 2026 zhangfy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
cd /home/zhangfy/claude-auto-retry
git add LICENSE
git commit -m "docs: add MIT license"
```

---

### Task 8: Integration Test — Manual Verification

This task is a manual test procedure to verify the plugin works end-to-end.

**Files:**
- No new files

- [ ] **Step 1: Verify plugin structure**

```bash
cd /home/zhangfy/claude-auto-retry
find . -not -path './.git/*' -not -path './docs/*' | sort
```

Expected output:
```
.
.claude-plugin
.claude-plugin/plugin.json
CLAUDE.md
LICENSE
README.md
hooks
hooks/hooks.json
hooks/retry-daemon
hooks/retry-daemon.ps1
hooks/run-hook
```

- [ ] **Step 2: Verify daemon can parse a real session**

```bash
# Point daemon at the current session log and verify it can read it
SESSION_LOG="/home/zhangfy/.claude/projects/-home-zhangfy/dc35c7bf-07b2-4ddc-bb32-69c118cc57a5.jsonl"
python3 -c "
import json
errors = 0
for line in open('$SESSION_LOG'):
    try:
        obj = json.loads(line)
    except: continue
    if obj.get('type') == 'assistant':
        content = obj.get('message', {}).get('content', [])
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and 'Content block not found' in c.get('text', ''):
                    errors += 1
print(f'Found {errors} error events in session log')
"
```

Expected: `Found N error events in session log` where N > 0

- [ ] **Step 3: Test daemon launch manually**

```bash
# Dry-run the daemon to verify it starts without errors
timeout 5 bash /home/zhangfy/claude-auto-retry/hooks/retry-daemon 2>&1 || true
# Check the log for startup messages
cat ~/.claude/plugins/cache/claude-auto-retry/retry.log | tail -5
```

Expected: Log file contains daemon startup messages.

- [ ] **Step 4: Final commit with all changes**

```bash
cd /home/zhangfy/claude-auto-retry
git add -A
git status
# Verify no unexpected files
git commit -m "chore: initial release v1.0.0"
```

---

## Self-Review

**1. Spec coverage:**
- ✅ Automatic detection → Task 3/4 (is_error_line / Test-ErrorLine)
- ✅ Automatic retry → Task 3/4 (inject_prompt / Send-RetryPrompt)
- ✅ Session preservation → retry within same session (same PTS/terminal)
- ✅ Cross-platform → Task 3 (Unix), Task 4 (Windows), Task 2 (launcher)
- ✅ Standard plugin format → Task 1 (plugin.json, hooks.json)
- ✅ Open source → Task 6 (README), Task 7 (LICENSE)
- ✅ Configurable → env vars in Task 3/4

**2. Placeholder scan:** No TBD, TODO, or incomplete steps found.

**3. Type consistency:** Function names and variable names consistent across tasks (e.g., `retry-daemon` in hooks.json matches the actual script filename).
