# Uninstall.ps1 —— 停用 Claude娘（由「停用Claude娘.cmd」调用）
$ErrorActionPreference = 'Continue'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $AppDir 'Common.ps1')

Write-Host ''
Write-Host '  停用 Claude娘' -ForegroundColor DarkYellow
Write-Host ''

# 1. 请正在运行的 Claude娘 退出
$asked = $false
try { [void]([Threading.EventWaitHandle]::OpenExisting('Local\ClaudeNiang.Exit')).Set(); $asked = $true } catch { }
if ($asked) { Start-Sleep -Milliseconds 1500 }
try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ClaudeNiang.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
Write-Host '  √ 已退出' -ForegroundColor Green

# 2. 移除开机自启
Set-CNAutostart $false $AppDir
Write-Host '  √ 已移除开机自启' -ForegroundColor Green

# 3. 卸载配套插件
$a = Read-Host '是否同时卸载 Claude 里的配套插件 xiaoke-quota？[Y/n]'
if ([string]::IsNullOrWhiteSpace($a) -or $a.Trim().ToLowerInvariant() -in @('y', 'yes', '是')) {
    $p = Uninstall-CNPlugin
    if ($p.code -eq 'nocli') { Write-Host '  · 没找到 Claude Code 引擎，请在 Claude 的「设置 → 插件」里手动移除 xiaoke-quota。' }
    else { Write-Host '  √ 已卸载配套插件（新开的 Claude 会话生效）' -ForegroundColor Green }
}

# 4. 移除状态栏桥接（只有旧版本或手动安装过才会有）
$r = Uninstall-CNBridge
if ($r.code -eq 'removed') { Write-Host '  √ 已从 ~/.claude/settings.json 移除状态栏桥接（备份：settings.json.claude-niang.bak）' -ForegroundColor Green }
elseif ($r.code -ne 'none') { Write-Host '  × 移除状态栏桥接失败，请手动删除 settings.json 中的 statusLine 配置。' -ForegroundColor Red }

# 4. 数据目录
$dataDir = Get-CNDataDir
Write-Host ''
$a = Read-Host "是否同时删除数据目录（位置、设置、自定义语录）？$dataDir [y/N]"
if ($a -and $a.Trim().ToLowerInvariant() -in @('y', 'yes', '是')) {
    Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  √ 已删除数据目录' -ForegroundColor Green
} else {
    Write-Host '  · 保留数据目录（重新安装后设置会自动恢复）'
}
Write-Host ''
Write-Host '完成。现在可以移动或删除程序文件夹了。'
Write-Host ''
