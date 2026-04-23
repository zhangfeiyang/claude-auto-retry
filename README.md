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

### Via Claude Code Plugin Install (Recommended)

```bash
claude plugins install github:<your-username>/claude-auto-retry
```

### Manual Installation

Clone into your plugins directory:

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