# Install.ps1 —— Claude娘 安装向导（由「安装Claude娘.cmd」调用）
$ErrorActionPreference = 'Stop'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProgramRoot = Split-Path -Parent $AppDir
. (Join-Path $AppDir 'Common.ps1')

function Ask([string]$q, [bool]$default = $true) {
    $hint = '[Y/n]'; if (-not $default) { $hint = '[y/N]' }
    $a = Read-Host "$q $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return ($a.Trim().ToLowerInvariant() -in @('y', 'yes', '是', '好'))
}

Write-Host ''
Write-Host '  Claude娘 —— 贴在 Claude 窗口右下角、陪你看剩余额度的看板娘' -ForegroundColor DarkYellow
Write-Host '  角色「小克」立绘/动画来自 aklnaaw/dsh-xiaoke-widget（CC BY-NC-SA 4.0，仅限非商业使用）' -ForegroundColor DarkGray
Write-Host ''

if ($PSVersionTable.PSVersion.Major -lt 5) { Write-Host '需要 Windows PowerShell 5.1 或更高版本。' -ForegroundColor Red; exit 1 }
if ($AppDir -match '\\AppData\\Local\\Temp\\' -or $AppDir -match '\.zip\\') {
    Write-Host '看起来你是在压缩包里直接运行的。请先把整个文件夹解压到固定位置（例如 D:\Tools\ClaudeNiang）再安装。' -ForegroundColor Yellow
    if (-not (Ask '仍然继续？' $false)) { exit 1 }
}

$dataDir = Get-CNDataDir
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
Write-Host "程序目录：$ProgramRoot"
Write-Host "数据目录：$dataDir"
Write-Host ''

# 1. 配套插件：在 Claude 里读取官方额度，写给挂件
Write-Host '【额度数据】配套插件 xiaoke-quota 会在 Claude 桌面 App（Code）里读取官方的 5 小时 / 每周剩余额度，交给 Claude娘 显示。' -ForegroundColor Cyan
Write-Host '它只读额度，不需要登录或任何 key；安装后会出现在 Claude 的「设置 → 插件」里，每个会话都会启用。'
if (Ask '安装配套插件？' $true) {
    $r = Install-CNPlugin $ProgramRoot
    if ($r.code -eq 'nocli') {
        Write-Host '  × 没找到 2.1.275 以上的 Claude Code 引擎。请先打开一次 Claude 桌面 App 的 Code 页面，再重新运行安装。' -ForegroundColor Red
    } elseif ($r.ok) {
        Write-Host '  √ 插件已安装（新开的 Claude 会话生效）' -ForegroundColor Green
    } else {
        Write-Host '  × 插件安装失败：' -ForegroundColor Red
        Write-Host ('    ' + ($r.output -replace "`n", "`n    "))
    }
}
Write-Host ''

# 2. 自动启动
Write-Host '【自动启动】' -ForegroundColor Cyan
Write-Host '  1. 随 Claude 启动：Claude 桌面 App 打开时自动出现，Claude 退出时一起退出（推荐）'
Write-Host '  2. 开机自启：登录 Windows 后就启动'
Write-Host '  3. 不自动启动：需要时双击「打开Claude娘.cmd」'
$a = Read-Host '请选择 [1/2/3，默认 1]'
$mode = 'claude'
if ($a -and $a.Trim() -eq '2') { $mode = 'logon' } elseif ($a -and $a.Trim() -eq '3') { $mode = 'off' }
Write-Host ''

# 3. 先让正在运行的旧挂件、旧的小助手退出（可能来自别的程序位置），再按新的设置启动
try { [void]([Threading.EventWaitHandle]::OpenExisting('Local\ClaudeNiang.Exit')).Set(); Start-Sleep -Milliseconds 1500 } catch { }
Stop-CNWatcher
try {
    Set-CNStartMode $mode $AppDir
    switch ($mode) {
        'claude' { Write-Host '  √ 已设置为随 Claude 启动（「启动」文件夹里的快捷方式：Claude娘（随 Claude 启动））' -ForegroundColor Green }
        'logon'  { Write-Host '  √ 已添加到「启动」文件夹' -ForegroundColor Green }
        default  { Write-Host '  · 不自动启动' }
    }
} catch {
    Write-Host ('  × 设置自动启动失败：' + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ''
Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $AppDir 'launch.vbs') + '"')
Write-Host 'Claude娘 已启动！她会贴在 Claude 窗口的右下角：' -ForegroundColor Green
Write-Host '  · 左键点她：查看剩余额度    · 点泡泡：翻页        · 按住拖动：调整位置'
Write-Host '  · 右键：设置菜单            · Ctrl + 滚轮：缩放   · 托盘图标：显示/隐藏'
Write-Host '  · 拖到 Claude 窗口或屏幕的边上会自动吸附，不会压到任务栏'
Write-Host '以后可以双击「打开Claude娘.cmd」重新打开；移动程序文件夹前请先运行「停用Claude娘.cmd」。'
Write-Host ''
