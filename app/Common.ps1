# Common.ps1 —— 安装器与主程序共用的函数（开机自启、状态栏桥接）
Set-StrictMode -Off

if (-not (Get-Command Get-CNClaudeDir -ErrorAction SilentlyContinue)) {
    function Get-CNClaudeDir {
        if ($env:CLAUDE_CONFIG_DIR -and (Test-Path -LiteralPath $env:CLAUDE_CONFIG_DIR)) { return $env:CLAUDE_CONFIG_DIR }
        return (Join-Path $env:USERPROFILE '.claude')
    }
}

function Get-CNDataDir { return (Join-Path $env:LOCALAPPDATA 'ClaudeNiang') }

# ---------------------------------------------------------------- 自动启动（当前用户“启动”文件夹快捷方式）
#   claude：随 Claude 启动——登录后常驻一个很小的 ClaudeNiangWatch.exe（见 Watch.cs），Claude 桌面 App 打开时叫出 Claude娘、退出时一起退出
#   logon ：开机自启——登录后直接启动 Claude娘
#   off   ：不自动启动

function Get-CNStartupLink { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude娘.lnk') }
function Get-CNWatchLink { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude娘（随 Claude 启动）.lnk') }
function Get-CNWatcherExe { return (Join-Path (Get-CNDataDir) 'ClaudeNiangWatch.exe') }

function Get-CNStartMode {
    if (Test-Path -LiteralPath (Get-CNWatchLink)) { return 'claude' }
    if (Test-Path -LiteralPath (Get-CNStartupLink)) { return 'logon' }
    return 'off'
}

function New-CNShortcut([string]$Lnk, [string]$Target, [string]$Arguments, [string]$WorkDir, [string]$Desc) {
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($Lnk)
    $sc.TargetPath = $Target
    $sc.Arguments = $Arguments
    $sc.WorkingDirectory = $WorkDir
    $sc.Description = $Desc
    $sc.Save()
}

function Stop-CNWatcher {
    Get-Process -Name 'ClaudeNiangWatch' -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill(); [void]$_.WaitForExit(2000) } catch { } }
}

# 把 Watch.cs 编译成 exe（源码变了才重新编译）
function Install-CNWatcher([string]$AppDir) {
    $src = Join-Path $AppDir 'Watch.cs'
    $exe = Get-CNWatcherExe
    $stamp = $exe + '.sha256'
    $hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $stamp) -and ([IO.File]::ReadAllText($stamp).Trim() -eq $hash)) { return $exe }
    $dir = Split-Path -Parent $exe
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Stop-CNWatcher
    if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
    Add-Type -Path $src -OutputAssembly $exe -OutputType WindowsApplication -ErrorAction Stop
    [IO.File]::WriteAllText($stamp, $hash)
    return $exe
}

# 现在就把小助手跑起来（不用等下次登录）；--baseline：Claude 此刻已经开着的话不重复叫出挂件
function Start-CNWatcher([string]$AppDir) {
    $exe = Install-CNWatcher $AppDir
    Start-Process -FilePath $exe -ArgumentList @(('"' + $AppDir + '"'), ('"' + (Get-CNWatchLink) + '"'), '--baseline') -WorkingDirectory $AppDir
}

function Set-CNStartMode([string]$Mode, [string]$AppDir) {
    if ($Mode -eq 'claude') { $exe = Install-CNWatcher $AppDir }   # 先编译，失败就保持原样
    foreach ($l in (Get-CNStartupLink), (Get-CNWatchLink)) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force } }
    switch ($Mode) {
        'claude' {
            New-CNShortcut (Get-CNWatchLink) $exe (('"' + $AppDir + '"') + ' ' + ('"' + (Get-CNWatchLink) + '"')) $AppDir 'Claude娘：Claude 桌面 App 打开时自动出现'
            Start-CNWatcher $AppDir
        }
        'logon' {
            New-CNShortcut (Get-CNStartupLink) (Join-Path $env:WINDIR 'System32\wscript.exe') ('"' + (Join-Path $AppDir 'launch.vbs') + '"') $AppDir 'Claude娘 桌面看板娘'
        }
    }
    # 其他模式下小助手发现自己的快捷方式没了会自己退出；这里直接结束，立刻生效
    if ($Mode -ne 'claude') { Stop-CNWatcher }
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
