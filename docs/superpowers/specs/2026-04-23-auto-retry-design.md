---
name: claude-auto-retry
description: Claude Code plugin that automatically retries on "Content block not found" API errors
type: project
---

# Claude Auto Retry — Design Spec

## Problem

Claude Code interactive sessions occasionally encounter `"API Error: Content block not found"` errors. These are transient API-side failures (incomplete streaming responses, content block parsing errors) that resolve on retry. Currently the user must manually notice the error and re-submit their prompt, which is disruptive especially during long autonomous tasks.

## Goal

Build a Claude Code plugin that automatically detects this error and retries the last user prompt without manual intervention, preserving the full session context.

## Requirements

1. **Automatic detection** — Monitor session logs for "Content block not found" errors
2. **Automatic retry** — Re-submit the last user prompt to Claude Code's terminal
3. **Session preservation** — Keep full conversation history (retry within the same session)
4. **Cross-platform** — Support both Unix (Linux/macOS) and Windows
5. **Standard plugin format** — Follow Claude Code's plugin structure for easy installation
6. **Open source** — Standalone project, publishable to GitHub, installable by anyone

## Architecture

### Plugin Structure

```
claude-auto-retry/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata
├── hooks/
│   ├── hooks.json            # SessionStart hook registration
│   ├── run-hook              # Cross-platform polyglot launcher
│   ├── retry-daemon          # Unix daemon (Bash)
│   └── retry-daemon.ps1      # Windows daemon (PowerShell)
├── CLAUDE.md                 # Plugin instructions for AI agents
├── README.md                 # User documentation
├── LICENSE                   # MIT license
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-04-23-auto-retry-design.md
```

### Data Flow

```
Claude Code starts
  → SessionStart hook fires
    → run-hook launches retry-daemon
      → daemon reads session info (PTS number, session ID, project path)
      → daemon tails the session .jsonl log
      → on "Content block not found" detection:
          → extract last user prompt from log
          → inject prompt into terminal (platform-specific)
          → wait 2s, check again
          → repeat up to 3 times
```

### Error Detection

The daemon monitors the session JSONL log for lines matching:

1. `type: "assistant"`
2. `message.content[*].text` contains `"Content block not found"`
3. Optionally: `message.model: "<synthetic>"` and `message.stop_reason: "stop_sequence"` (stronger signal)

The detection uses a combination of these signals to avoid false positives from user messages that merely mention the error text.

### Retry Mechanism

#### Unix (Linux / macOS)

```bash
echo "$last_prompt" > /dev/pts/$PTS_NUM
```

- Requires write permission to the TTY device (typically `crw--w----` for the user)
- The PTS number is obtained from the session file in `~/.claude/sessions/`

#### Windows

```powershell
$shell = New-Object -ComObject WScript.Shell
$shell.AppActivate($windowTitle)
Start-Sleep -Milliseconds 100
$shell.SendKeys("$lastPrompt{ENTER}")
```

- Uses WScript.Shell COM object to send keystrokes
- Requires Claude Code window to be in the foreground (or at least not minimized)
- May be blocked by UAC or security software in some environments

### Retry Strategy

- **Max retries**: 3 (configurable)
- **Interval**: 2 seconds between retries (configurable)
- **Retry prompt**: The exact text of the last `type: "user"` message's `content` field
- **Log**: Each retry attempt is logged to `~/.claude/plugins/cache/claude-auto-retry/retry.log`

### Session Discovery

The daemon needs to identify:

1. **Session file**: `~/.claude/sessions/<PID>.json` — contains `sessionId`, `cwd`, process info
2. **Session log**: `~/.claude/projects/<escaped-cwd>/<sessionId>.jsonl` — the JSONL conversation log
3. **Terminal device**: Derived from `/proc/<PID>/fd/0` on Linux; from the session file on other platforms

The SessionStart hook receives environment variables:
- `CLAUDE_SESSION_ID` — the current session UUID
- `CLAUDE_PROJECT_DIR` — the current working directory
- The hook script can also inspect `~/.claude/sessions/` to find the active session

### Daemon Lifecycle

1. **Start**: Launched by SessionStart hook, runs in background
2. **Monitor**: Tails the session JSONL log using `tail -f` (Unix) or `Get-Content -Wait` (Windows)
3. **Detect**: Filters for error patterns
4. **Retry**: Injects prompt into terminal
5. **Stop**: Daemon exits when:
   - Session process (`claude`) is no longer running (checked every 10s)
   - Maximum retries exhausted without success
   - Explicitly killed

## Configuration

Default values (can be overridden via environment variables):

| Setting | Env Var | Default | Description |
|---------|---------|---------|-------------|
| Max retries | `CLAUDE_RETRY_MAX` | 3 | Maximum retry attempts |
| Retry interval | `CLAUDE_RETRY_INTERVAL` | 2 | Seconds between retries |
| Error pattern | `CLAUDE_RETRY_PATTERN` | `Content block not found` | Regex pattern to detect |
| Log file | `CLAUDE_RETRY_LOG` | `~/.claude/plugins/cache/claude-auto-retry/retry.log` | Log file path |

## Error Handling

- **Daemon crash**: No recovery needed — the session continues normally without auto-retry. User can still retry manually.
- **Log file not found**: Daemon exits silently with a warning log.
- **TTY write failure**: Daemon logs the error, continues monitoring for the next occurrence.
- **False positive**: Unlikely given the multi-signal detection, but if it occurs, Claude Code receives a duplicate prompt which is harmless.

## Limitations

| Platform | Limitation |
|----------|------------|
| Unix | Requires TTY write permission (usually satisfied) |
| Windows | Requires Claude Code window in foreground for SendKeys |
| Windows | SendKeys may be blocked by security software |
| All | Cannot retry if session log is not being written to disk |
| All | Very rapid successive errors (within 2s) may cause duplicate retries |

## Testing Plan

1. **Unit**: Test error detection regex against real session log samples
2. **Integration**: Manually trigger the error and verify daemon detects and retries
3. **Cross-platform**: Test on Linux (primary), macOS, and Windows
4. **Edge cases**: Test with empty prompts, very long prompts, special characters in prompts

## Open Questions (Resolved)

- ~~Windows compatibility?~~ → Yes, using PowerShell SendKeys
- ~~Session history preservation?~~ → Yes, retry within same session
- ~~Trigger mode?~~ → Fully automatic, no user intervention
