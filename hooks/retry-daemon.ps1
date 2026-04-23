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
        $activated = $shell.AppActivate("claude")
        if (-not $activated) {
            $activated = $shell.AppActivate("Claude Code")
        }
        if ($activated) {
            Start-Sleep -Milliseconds 200
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

Get-Content $sessionLog -Wait | ForEach-Object {
    $line = $_

    $proc = Get-Process -Id $sessionPid -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Log "Claude process $sessionPid exited, stopping daemon"
        break
    }

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