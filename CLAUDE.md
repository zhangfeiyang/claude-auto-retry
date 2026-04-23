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