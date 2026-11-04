# Common.ps1 —— 安装器与主程序共用的函数（开机自启、状态栏桥接）
Set-StrictMode -Off

if (-not (Get-Command Get-CNClaudeDir -ErrorAction SilentlyContinue)) {
    function Get-CNClaudeDir {
        if ($env:CLAUDE_CONFIG_DIR -and (Test-Path -LiteralPath $env:CLAUDE_CONFIG_DIR)) { return $env:CLAUDE_CONFIG_DIR }
        return (Join-Path $env:USERPROFILE '.claude')
    }
}

function Get-CNDataDir { return (Join-Path $env:LOCALAPPDATA 'ClaudeNiang') }

# ---------------------------------------------------------------- 开机自启（当前用户“启动”文件夹快捷方式）

function Get-CNStartupLink { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude娘.lnk') }

function Test-CNAutostart { return (Test-Path -LiteralPath (Get-CNStartupLink)) }

function Set-CNAutostart([bool]$On, [string]$AppDir) {
    $lnk = Get-CNStartupLink
    if ($On) {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $sc.Arguments = '"' + (Join-Path $AppDir 'launch.vbs') + '"'
        $sc.WorkingDirectory = $AppDir
        $sc.Description = 'Claude娘 桌面看板娘'
        $sc.Save()
    } elseif (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force
    }
}

# ---------------------------------------------------------------- 配套插件 xiaoke-quota（给挂件提供官方额度）

# 找一个支持插件 hooks 模块的 Claude Code 引擎（2.1.275+）：优先用桌面 App 自带的最新版，其次 PATH 里的 claude
function Find-CNClaudeCli {
    $cands = @()
    $root = Join-Path $env:LOCALAPPDATA 'Claude-Data'
    if (Test-Path -LiteralPath $root) {
        foreach ($exe in Get-ChildItem -LiteralPath $root -Recurse -Filter 'claude.exe' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\claude-code\\(\d+\.\d+\.\d+)\\' }) {
            $null = $exe.FullName -match '\\claude-code\\(\d+\.\d+\.\d+)\\'
            $cands += [pscustomobject]@{ Path = $exe.FullName; Version = [version]$Matches[1] }
        }
    }
    $onPath = Get-Command claude -ErrorAction SilentlyContinue
    if ($onPath) {
        try {
            $v = (& $onPath.Source --version 2>$null | Select-Object -First 1)
            if ($v -match '(\d+\.\d+\.\d+)') { $cands += [pscustomobject]@{ Path = $onPath.Source; Version = [version]$Matches[1] } }
        } catch { }
    }
    $best = $cands | Where-Object { $_.Version -ge [version]'2.1.275' } | Sort-Object Version -Descending | Select-Object -First 1
    if ($best) { return $best.Path }
    return $null
}

function Install-CNPlugin([string]$ProgramRoot) {
    $cli = Find-CNClaudeCli
    if (-not $cli) { return @{ ok = $false; code = 'nocli' } }
    $out = & $cli plugin install xiaoke-quota --marketplace $ProgramRoot -y 2>&1 | Out-String
    return @{ ok = ($LASTEXITCODE -eq 0); code = 'ran'; output = $out.Trim(); cli = $cli }
}

function Uninstall-CNPlugin {
    $cli = Find-CNClaudeCli
    if (-not $cli) { return @{ ok = $false; code = 'nocli' } }
    $out = (& $cli plugin uninstall 'xiaoke-quota@xiaoke-local' -y 2>&1 | Out-String) + (& $cli plugin marketplace remove xiaoke-local 2>&1 | Out-String)
    return @{ ok = $true; code = 'ran'; output = $out.Trim() }
}

# ---------------------------------------------------------------- 状态栏桥接（可选，写入 ~/.claude/settings.json 的 statusLine）

function Get-CNSettingsPath { return (Join-Path (Get-CNClaudeDir) 'settings.json') }

function Test-CNBridgeInstalled {
    $p = Get-CNSettingsPath
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    try { return ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) -match 'statusline-bridge') } catch { return $false }
}

# 返回 @{ ok; code; existing }
#   code: installed / already / exists(已有别的状态栏，不覆盖) / badjson / verify
function Install-CNBridge([string]$AppDir) {
    $dataDir = Get-CNDataDir
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
    $dst = Join-Path $dataDir 'statusline-bridge.ps1'
    Copy-Item -LiteralPath (Join-Path $AppDir 'statusline-bridge.ps1') -Destination $dst -Force

    $settings = Get-CNSettingsPath
    $claudeDir = Split-Path -Parent $settings
    if (-not (Test-Path -LiteralPath $claudeDir)) { New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null }
    $text = ''
    if (Test-Path -LiteralPath $settings) { $text = [IO.File]::ReadAllText($settings, [Text.Encoding]::UTF8) }

    if ($text.Trim().Length -gt 0) {
        try { $obj = $text | ConvertFrom-Json } catch { return @{ ok = $false; code = 'badjson' } }
        if ($obj -and ($obj.PSObject.Properties.Name -contains 'statusLine')) {
            $existing = ''
            try { $existing = [string]$obj.statusLine.command } catch { }
            if ($existing -match 'statusline-bridge') { return @{ ok = $true; code = 'already' } }
            return @{ ok = $false; code = 'exists'; existing = $existing }
        }
    }

    # Windows 上 Claude Code 可能用 Git Bash 执行状态栏命令，所以路径用正斜杠
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + ($dst -replace '\\', '/') + '"'
    $cmdJson = $cmd.Replace('\', '\\').Replace('"', '\"')
    $entry = '"statusLine": { "type": "command", "command": "' + $cmdJson + '" }'
    $trim = $text.Trim()
    if ($trim.Length -eq 0 -or $trim -match '^\{\s*\}$') {
        $new = "{`n  " + $entry + "`n}`n"
    } else {
        $i = $text.IndexOf('{')
        $new = $text.Substring(0, $i + 1) + "`n  " + $entry + ',' + $text.Substring($i + 1)
    }
    try { $chk = $new | ConvertFrom-Json; if (-not $chk.statusLine) { throw 'x' } } catch { return @{ ok = $false; code = 'verify' } }

    if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings -Destination ($settings + '.claude-niang.bak') -Force }
    [IO.File]::WriteAllText($settings, $new, (New-Object Text.UTF8Encoding($false)))
    return @{ ok = $true; code = 'installed' }
}

function Uninstall-CNBridge {
    $settings = Get-CNSettingsPath
    if (-not (Test-Path -LiteralPath $settings)) { return @{ ok = $true; code = 'none' } }
    $text = [IO.File]::ReadAllText($settings, [Text.Encoding]::UTF8)
    if ($text -notmatch 'statusline-bridge') { return @{ ok = $true; code = 'none' } }
    $new = [regex]::Replace($text, '\s*"statusLine"\s*:\s*\{[^{}]*statusline-bridge[^{}]*\}\s*,?', '', 1)
    # 若 statusLine 是最后一个键，去掉残留的尾逗号
    $new = [regex]::Replace($new, ',(\s*)\}\s*$', '$1}')
    try { $null = $new | ConvertFrom-Json } catch { return @{ ok = $false; code = 'verify' } }
    Copy-Item -LiteralPath $settings -Destination ($settings + '.claude-niang.bak') -Force
    [IO.File]::WriteAllText($settings, $new, (New-Object Text.UTF8Encoding($false)))
    return @{ ok = $true; code = 'removed' }
}
