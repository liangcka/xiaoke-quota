# statusline-bridge.ps1 —— Claude Code 状态栏桥接
# Claude Code 每次刷新状态栏时会把会话 JSON 通过 stdin 传给本脚本。
# 本脚本只把其中官方的 rate_limits（5 小时 / 7 天用量百分比与重置时间）存到
# %LOCALAPPDATA%\ClaudeNiang\bridge.json 给 Claude娘读取，然后输出一行简短状态栏文字。
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { }
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }

$raw = [Console]::In.ReadToEnd()
$j = $null
try { $j = $raw | ConvertFrom-Json } catch { }

$dir = Join-Path $env:LOCALAPPDATA 'ClaudeNiang'
if ($j -and $j.rate_limits) {
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $out = [ordered]@{
            captured_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            rate_limits = $j.rate_limits
            model       = [string]$j.model.display_name
            version     = [string]$j.version
        }
        $dst = Join-Path $dir 'bridge.json'
        $tmp = Join-Path $dir ('bridge.' + $PID + '.tmp')
        [IO.File]::WriteAllText($tmp, ($out | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $dst) { [IO.File]::Replace($tmp, $dst, $null) } else { [IO.File]::Move($tmp, $dst) }
    } catch { }
}

# 输出状态栏文字（显示剩余百分比，与 Claude娘 一致）
$parts = @()
if ($j -and $j.model -and $j.model.display_name) { $parts += [string]$j.model.display_name }
if ($j -and $j.rate_limits) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($pair in @(@('five_hour', '5h'), @('seven_day', '7d'))) {
        $w = $j.rate_limits.($pair[0])
        if ($w -and $null -ne $w.used_percentage) {
            $rem = [Math]::Max(0, [Math]::Round(100 - [double]$w.used_percentage))
            $parts += ('{0} {1}%' -f $pair[1], $rem)
        }
    }
} elseif ($j -and $j.context_window -and $null -ne $j.context_window.used_percentage) {
    $parts += ('ctx {0}%' -f [Math]::Round([double]$j.context_window.used_percentage))
}
if ($parts.Count -gt 0) { [Console]::Out.Write(($parts -join ' · ')) }
