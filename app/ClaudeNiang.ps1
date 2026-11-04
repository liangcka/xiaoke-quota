#requires -version 5.1
# ClaudeNiang.ps1 —— Claude娘：陪你看 Claude 剩余额度的桌面看板娘
#   -RenderTest -RenderOut x.png [-RenderState quota|week|quote|cry|nodata|flip]  只渲染一张预览图后退出（开发用）
#   -SelfTest N                                                                    运行 N 秒并自动执行各项操作后退出（开发用）
param([switch]$RenderTest, [string]$RenderOut = '', [string]$RenderState = 'quota', [double]$RenderScale = 1.5, [int]$SelfTest = 0)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing

$AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $env:LOCALAPPDATA 'ClaudeNiang'
if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }
. (Join-Path $AppDir 'Collector.ps1')
. (Join-Path $AppDir 'Common.ps1')

$S = @{ Version = '1.1.1' }
$S.LogPath = Join-Path $DataDir 'log.txt'
function Write-CNLog([string]$Msg) {
    try {
        if ((Test-Path -LiteralPath $S.LogPath) -and (Get-Item -LiteralPath $S.LogPath).Length -gt 512KB) { Remove-Item -LiteralPath $S.LogPath -Force }
        Add-Content -LiteralPath $S.LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) -Encoding UTF8
    } catch { }
}
function Write-CNMem([string]$Tag) {
    if (-not $env:CLAUDENIANG_MEMDEBUG) { return }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    $p = [Diagnostics.Process]::GetCurrentProcess()
    Write-CNLog ('内存[{0}] private {1:N0} MB, managed {2:N0} MB' -f $Tag, ($p.PrivateMemorySize64 / 1MB), ([GC]::GetTotalMemory($false) / 1MB))
}

# ---------------------------------------------------------------- 单实例
if (-not $RenderTest) {
    $created = $false
    $S.Mutex = New-Object Threading.Mutex($true, 'Local\ClaudeNiang.Singleton', [ref]$created)
    if (-not $created) {
        try { [void]([Threading.EventWaitHandle]::OpenExisting('Local\ClaudeNiang.Show')).Set() } catch { }
        return
    }
    $S.ShowEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\ClaudeNiang.Show')
    $S.ExitEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\ClaudeNiang.Exit')
    # 我们已拿到单实例锁：启动前遗留的信号（例如发给上一个实例、它没来得及处理的退出信号）一律作废
    [void]$S.ExitEvent.Reset(); [void]$S.ShowEvent.Reset()
}
Write-CNLog "启动 v$($S.Version)"
Write-CNMem '启动'

# ---------------------------------------------------------------- C# 辅助（编译一次后缓存成 DLL）
$S.NativeOk = $false
try {
    $cs = Join-Path $AppDir 'Native.cs'
    $hash = (Get-FileHash -LiteralPath $cs -Algorithm SHA256).Hash.Substring(0, 12)
    $dll = Join-Path $DataDir ("ClaudeNiang.Native.$hash.dll")
    $refs = @('PresentationCore', 'WindowsBase', 'System.Xaml')
    if (-not (Test-Path -LiteralPath $dll)) {
        try { Add-Type -Path $cs -ReferencedAssemblies $refs -OutputAssembly $dll -OutputType Library -ErrorAction Stop } catch { Write-CNLog "缓存 DLL 失败：$($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $dll) { Add-Type -Path $dll -ErrorAction Stop } else { Add-Type -Path $cs -ReferencedAssemblies $refs -ErrorAction Stop }
    $S.NativeOk = $true
} catch { Write-CNLog "Native 编译失败：$($_.Exception.Message)" }

# ---------------------------------------------------------------- 配置
$S.ConfigPath = Join-Path $DataDir 'config.json'
$Cfg = [ordered]@{
    left = $null; top = $null; scale = 1.5
    mode = 'follow'           # follow（贴在 Claude 窗口右下角，默认）/ desktop（自由拖动）
    topmost = $false; followDx = 0.0; followDy = 0.0
    muted = $false; volume = 0.55
    useApi = $true; autoQuoteMin = 0; lowMemory = $false
}
if (Test-Path -LiteralPath $S.ConfigPath) {
    try {
        $j = [IO.File]::ReadAllText($S.ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { if ($Cfg.Contains($p.Name)) { $Cfg[$p.Name] = $p.Value } }
    } catch { Write-CNLog '配置文件损坏，已使用默认值' }
}
$Cfg.scale = [Math]::Max(0.6, [Math]::Min(2.5, [double]$Cfg.scale))
function Save-CNConfig {
    if ($RenderTest) { return }
    try { [IO.File]::WriteAllText($S.ConfigPath, ($Cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) } catch { }
}
function Request-CNSave { $S.SaveDue = [DateTime]::UtcNow.AddSeconds(1.5) }

# ---------------------------------------------------------------- 语录
$S.QuotesPath = Join-Path $DataDir 'quotes.txt'
if (-not (Test-Path -LiteralPath $S.QuotesPath)) { Copy-Item -LiteralPath (Join-Path $AppDir 'quotes.txt') -Destination $S.QuotesPath }
function Import-CNQuotes {
    $q = @()
    try { $q = @(Get-Content -LiteralPath $S.QuotesPath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) } catch { }
    if ($q.Count -eq 0) { $q = @('今天也一起加油吧～') }
    $S.Quotes = $q
}
Import-CNQuotes
$S.Rand = New-Object Random

# ---------------------------------------------------------------- 界面
# 布局照搬原项目：正方形挂件，小克在右下角占 59.45%，思考泡泡（1026×700 坐标系）铺在左上。
# 在屏幕左半边时整体水平翻转（文字再反向翻回来）。
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude娘" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" ShowActivated="False" Topmost="False"
        Width="320" Height="320" FontFamily="Microsoft YaHei UI" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Grid x:Name="Root" Width="320" Height="320">
    <Grid x:Name="Stage" RenderTransformOrigin="0.5,0.5">
      <Grid.RenderTransform><ScaleTransform x:Name="FlipT" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>

      <Image x:Name="CharImg" Width="190.24" Height="190.24" Stretch="Fill"
             HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="Hand"
             RenderOptions.BitmapScalingMode="HighQuality" RenderTransformOrigin="0.5,1">
        <Image.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="BreathT" ScaleX="1" ScaleY="1"/>
            <ScaleTransform x:Name="SquashT" ScaleX="1" ScaleY="1"/>
          </TransformGroup>
        </Image.RenderTransform>
      </Image>

      <Viewbox x:Name="BubbleBox" Width="320" Height="218.32" Stretch="Fill"
               HorizontalAlignment="Left" VerticalAlignment="Top" IsHitTestVisible="False">
        <Canvas Width="1026" Height="700">
          <Path x:Name="BShape" Fill="#FFFAF9F5" Stroke="#FFD97757" StrokeThickness="26"
                StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0" Cursor="Hand"
                Data="M 827 248 A 373 232 0 1 0 81 246 A 373 232 0 0 0 301 465 A 57 32 10 0 0 413 484 A 373 232 0 0 0 827 248 Z">
            <Path.RenderTransform><ScaleTransform x:Name="BShapeT" CenterX="454" CenterY="250" ScaleX="0.7" ScaleY="0.7"/></Path.RenderTransform>
          </Path>
          <Ellipse x:Name="B1" Canvas.Left="301.5" Canvas.Top="522" Width="101" Height="78"
                   Fill="#FFFAF9F5" Stroke="#FFD97757" StrokeThickness="26" Opacity="0" Cursor="Hand">
            <Ellipse.RenderTransform><ScaleTransform x:Name="B1T" CenterX="50.5" CenterY="39" ScaleX="0.7" ScaleY="0.7"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse x:Name="B2" Canvas.Left="404.5" Canvas.Top="615" Width="75" Height="62"
                   Fill="#FFFAF9F5" Stroke="#FFD97757" StrokeThickness="26" Opacity="0" Cursor="Hand">
            <Ellipse.RenderTransform><ScaleTransform x:Name="B2T" CenterX="37.5" CenterY="31" ScaleX="0.7" ScaleY="0.7"/></Ellipse.RenderTransform>
          </Ellipse>
          <Grid x:Name="TextBox" Canvas.Left="115.5" Canvas.Top="28" Width="677" Height="448"
                Opacity="0" IsHitTestVisible="False" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><ScaleTransform x:Name="TextFlipT" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
            <StackPanel x:Name="TextPanel" VerticalAlignment="Center" HorizontalAlignment="Center"/>
          </Grid>
        </Canvas>
      </Viewbox>
    </Grid>
  </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Parse($xaml)
Write-CNMem '界面已解析'
$U = @{}
foreach ($n in 'Root', 'Stage', 'FlipT', 'CharImg', 'BreathT', 'SquashT', 'BubbleBox', 'BShape', 'BShapeT', 'B1', 'B1T', 'B2', 'B2T', 'TextBox', 'TextFlipT', 'TextPanel') { $U[$n] = $window.FindName($n) }
$DR = 320.0          # 设计尺寸（正方形边长，100% 缩放时）
$CharFrac = 0.5945   # 小克占挂件边长的比例（与原项目一致）

# 按实际像素排版：窗口和小克都对齐到设备像素，动画帧按小克的像素尺寸生成后 1:1 显示，
# 不再整体缩放后二次插值（那样放大会糊，不放大也会轻微发虚）。泡泡是矢量，随窗口缩放。
function Set-CNLayout([double]$Scale) {
    $d = Get-CNDpi
    $wpx = [Math]::Round($DR * $Scale * $d)
    $spx = [Math]::Round($wpx * $CharFrac)
    $S.CharPx = [int]$spx
    $w = $wpx / $d
    $window.Width = $w; $window.Height = $w
    $U.Root.Width = $w; $U.Root.Height = $w
    $U.CharImg.Width = $spx / $d; $U.CharImg.Height = $spx / $d
    $U.BubbleBox.Width = $w; $U.BubbleBox.Height = $w * 700 / 1026
}

$S.BrushConv = New-Object Windows.Media.BrushConverter
$S.Brushes = @{}
function Get-CNBrush([string]$c) {
    if (-not $S.Brushes.ContainsKey($c)) { $b = $S.BrushConv.ConvertFromString($c); $b.Freeze(); $S.Brushes[$c] = $b }
    return $S.Brushes[$c]
}
function New-CNRainbow {
    $lg = New-Object Windows.Media.LinearGradientBrush
    $lg.StartPoint = '0,0'; $lg.EndPoint = '1,1'
    $i = 0
    foreach ($c in '#FFE0533F', '#FFE8902E', '#FFD9B21E', '#FF4FA35A', '#FF3B8FD0', '#FF8A5CC9') {
        $lg.GradientStops.Add((New-Object Windows.Media.GradientStop(([Windows.Media.ColorConverter]::ConvertFromString($c)), ($i / 5.0)))); $i++
    }
    $lg.Freeze()
    return $lg
}

# ---------------------------------------------------------------- 坐标与屏幕
function Get-CNDpi {
    try {
        $src = [Windows.PresentationSource]::FromVisual($window)
        if ($src -and $src.CompositionTarget) { return $src.CompositionTarget.TransformToDevice.M11 }
    } catch { }
    try { $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $d = $g.DpiX / 96.0; $g.Dispose(); return $d } catch { return 1.0 }
}
function Get-CNWorkArea {
    $d = Get-CNDpi
    $pt = New-Object Drawing.Point([int](($window.Left + $window.Width / 2) * $d), [int](($window.Top + $window.Height * 0.75) * $d))
    $wa = [Windows.Forms.Screen]::FromPoint($pt).WorkingArea
    return @{ X = $wa.X / $d; Y = $wa.Y / $d; W = $wa.Width / $d; H = $wa.Height / $d }
}
function Set-CNDefaultPosition {
    $d = Get-CNDpi
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $window.Left = ($wa.Right / $d) - $window.Width
    $window.Top = ($wa.Bottom / $d) - $window.Height
}
function Repair-CNPosition([bool]$Snap) {
    $wa = Get-CNWorkArea
    $w = $window.Width; $h = $window.Height
    $l = $window.Left; $t = $window.Top; $th = 28
    if ($Snap) {
        if ([Math]::Abs($l - $wa.X) -lt $th) { $l = $wa.X }
        if ([Math]::Abs(($l + $w) - ($wa.X + $wa.W)) -lt $th) { $l = $wa.X + $wa.W - $w }
        if ([Math]::Abs(($t + $h) - ($wa.Y + $wa.H)) -lt $th) { $t = $wa.Y + $wa.H - $h }
    }
    $l = [Math]::Max($wa.X, [Math]::Min($l, $wa.X + $wa.W - $w))
    $t = [Math]::Max($wa.Y - ($h * 0.35), [Math]::Min($t, $wa.Y + $wa.H - $h))
    $window.Left = $l; $window.Top = $t
}
# 在屏幕左半边时整体翻转：小克到左下、泡泡到右上，始终朝向屏幕内侧
function Update-CNFacing {
    try {
        $wa = Get-CNWorkArea
        $cx = $window.Left + $window.Width / 2
        $f = 1; if ($cx -lt ($wa.X + $wa.W / 2)) { $f = -1 }
        $U.FlipT.ScaleX = $f
        $U.TextFlipT.ScaleX = $f
    } catch { }
}

# ---------------------------------------------------------------- 角色（小克动画）
$S.AnimMeta = $null
try { $S.AnimMeta = [IO.File]::ReadAllText((Join-Path $AppDir 'assets\xiaoke\anim.json')) | ConvertFrom-Json } catch { Write-CNLog "anim.json 读取失败：$_" }
$S.Frames = $null; $S.FrameDur = $null; $S.FrameIdx = 0; $S.FrameSet = ''; $S.Loader = $null; $S.CharMode = ''

$S.AnimTimer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Render)
$S.AnimTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$S.AnimTimer.add_Tick({
    try {
        if (-not $S.Frames) { $S.AnimTimer.Stop(); return }
        $S.FrameIdx = ($S.FrameIdx + 1) % $S.Frames.Count
        $U.CharImg.Source = $S.Frames[$S.FrameIdx]
        $S.AnimTimer.Interval = [TimeSpan]::FromMilliseconds([int]$S.FrameDur[$S.FrameIdx])
    } catch { }
})

function Get-CNFramePx {
    $px = [int]$S.CharPx
    if ($px -le 0) { $px = [int][Math]::Round($DR * $CharFrac * [double]$Cfg.scale * (Get-CNDpi)) }
    $max = 384; if ($S.AnimMeta -and $S.AnimMeta.hd) { $max = 512 }
    return [int][Math]::Min($max, $px)   # 超过素材分辨率才交给 WPF 放大
}
function Stop-CNBreath {
    $U.BreathT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $U.BreathT.ScaleY = 1
}
function Show-CNStaticChar {
    $S.AnimTimer.Stop()
    if ($S.Loader) { try { $S.Loader.wf.Dispose() } catch { }; $S.Loader = $null }
    $S.Frames = $null; $S.CharMode = 'static'; $S.FrameSet = 'normal'
    if (-not $S.StaticImg) {
        $bi = New-Object Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.UriSource = New-Object Uri((Join-Path $AppDir 'assets\xiaoke\xiaoke1.png'))
        $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.EndInit(); $bi.Freeze()
        $S.StaticImg = $bi
    }
    $U.CharImg.Source = $S.StaticImg
    $e = New-Object Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'
    $a = New-Object Windows.Media.Animation.DoubleAnimation(1.0, 1.012, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(2200))))
    $a.EasingFunction = $e; $a.AutoReverse = $true; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $U.BreathT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $a)
}
function Start-CNCharLoad([string]$Set) {
    if ($Cfg.lowMemory -or -not $S.AnimMeta -or -not $S.NativeOk -or $S.WebpFailed) { Show-CNStaticChar; return }
    $meta = $S.AnimMeta.sets.$Set
    if (-not $meta) { Show-CNStaticChar; return }
    if ($S.Loader) { try { $S.Loader.wf.Dispose() } catch { }; $S.Loader = $null }
    $px = Get-CNFramePx
    # 小尺寸用 384px 素材；更大时换原项目的 512px 高清素材
    $file = $meta.file
    if ($px -gt 384 -and $S.AnimMeta.hd -and $S.AnimMeta.hd.$Set) { $file = $S.AnimMeta.hd.$Set }
    try {
        $wf = New-Object ClaudeNiang.WebpFrames((Join-Path $AppDir ('assets\xiaoke\' + $file)), $false)
        if ($wf.Count -lt 2) { throw '只解码出 1 帧' }
    } catch {
        Write-CNLog "WebP 动画不可用（可能缺少系统 WebP 解码器），改用静态立绘：$($_.Exception.Message)"
        $S.WebpFailed = $true; Show-CNStaticChar; return
    }
    # 尺寸较大时隔帧取用（眨眼的 15-22 帧全保留），内存减半，头发摆动仍然顺滑
    $all = @($meta.durations)
    $idx = New-Object 'System.Collections.Generic.List[int]'
    $durs = New-Object 'System.Collections.Generic.List[int]'
    $thin = $px -gt 320
    for ($i = 0; $i -lt [Math]::Min($all.Count, $wf.Count); $i++) {
        $dur = [int]$all[$i]
        $blink = ($i -ge 15 -and $i -le 22)
        $nextBlink = (($i + 1) -ge 15 -and ($i + 1) -le 22)
        if ($thin -and -not $blink -and -not $nextBlink -and ($i + 1) -lt $all.Count) { $dur += [int]$all[$i + 1]; $idx.Add($i); $durs.Add($dur); $i++ }
        else { $idx.Add($i); $durs.Add($dur) }
    }
    $S.Loader = @{ wf = $wf; set = $Set; k = 0; idx = $idx.ToArray(); list = (New-Object 'System.Collections.Generic.List[object]'); px = $px; durs = $durs.ToArray(); side = $wf.SourceWidth }
    if (-not $S.Frames) {
        try { $U.CharImg.Source = $wf.GetFrame(0, 0, 0, $S.Loader.side, $S.Loader.side, $px, $px) } catch { }
    }
    $S.LoaderTimer.Start()
}
$S.LoaderTimer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
$S.LoaderTimer.Interval = [TimeSpan]::FromMilliseconds(5)
$S.LoaderTimer.add_Tick({
    $L = $S.Loader
    if (-not $L) { $S.LoaderTimer.Stop(); return }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($L.k -lt $L.idx.Count -and $sw.ElapsedMilliseconds -lt 25) {
            $L.list.Add($L.wf.GetFrame($L.idx[$L.k], 0, 0, $L.side, $L.side, $L.px, $L.px))
            $L.k++
        }
        if ($L.k -ge $L.idx.Count) {
            $S.LoaderTimer.Stop()
            $L.wf.Dispose()
            Stop-CNBreath
            $S.Frames = $L.list.ToArray(); $S.FrameDur = $L.durs; $S.FrameSet = $L.set; $S.CharMode = 'anim'
            $S.Loader = $null
            Write-CNMem ('动画帧已加载 ' + $S.Frames.Count)
            if ($S.FrameIdx -ge $S.Frames.Count) { $S.FrameIdx = 0 }
            $U.CharImg.Source = $S.Frames[$S.FrameIdx]
            if ($window.IsVisible) { $S.AnimTimer.Start() }
            [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        }
    } catch {
        Write-CNLog "加载动画帧失败：$($_.Exception.Message)"
        $S.LoaderTimer.Stop(); $S.WebpFailed = $true; Show-CNStaticChar
    }
})
# 额度低时切换成“哭哭”动画（小克原版的余额预警表情）
function Update-CNExpression {
    if ($S.CharMode -eq 'static' -and ($Cfg.lowMemory -or $S.WebpFailed)) { return }
    $want = 'normal'
    if ($S.Worried) { $want = 'cry' }
    if ($S.Loader -and $S.Loader.set -eq $want) { return }
    if ($S.FrameSet -eq $want -and $S.CharMode -eq 'anim') { return }
    Start-CNCharLoad $want
}

# ---------------------------------------------------------------- 动效
function New-CNAnim($From, $To, [double]$Ms, $Ease = $null, [double]$DelayMs = 0) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    if ($null -ne $From) { $a.From = [double]$From }
    $a.To = [double]$To
    $a.Duration = New-Object Windows.Duration([TimeSpan]::FromMilliseconds($Ms))
    if ($Ease) { $a.EasingFunction = $Ease }
    if ($DelayMs -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($DelayMs) }
    return $a
}
# CSS 的 ease = cubic-bezier(.25,.1,.25,1)；按压用原项目的 cubic-bezier(.34,1.56,.64,1)
function New-CNBezier([double]$X1, [double]$Y1, [double]$X2, [double]$Y2) {
    if ($S.NativeOk) { return (New-Object ClaudeNiang.CubicBezierEase($X1, $Y1, $X2, $Y2)) }
    if ($Y1 -gt 1) { $e = New-Object Windows.Media.Animation.BackEase; $e.Amplitude = 0.35 } else { $e = New-Object Windows.Media.Animation.QuadraticEase }
    $e.EasingMode = 'EaseOut'
    return $e
}
$S.EaseCss = New-CNBezier 0.25 0.1 0.25 1.0
$S.EasePress = New-CNBezier 0.34 1.56 0.64 1.0

# 按压：压扁成 scaleY(0.88) scaleX(1.05)，以底边中点为原点；松开恢复。两段都是 0.22s，与原项目一致。
$S.PressAt = [DateTime]::MinValue
function Invoke-CNPress {
    $S.PressAt = [DateTime]::UtcNow
    $U.SquashT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-CNAnim $null 1.05 220 $S.EasePress))
    $U.SquashT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-CNAnim $null 0.88 220 $S.EasePress))
}
function Invoke-CNRelease {
    # 极短的点按：先落到压扁位置，再从那里恢复，保证每次点击都能看到“压一下”
    $fx = $null; $fy = $null
    if (([DateTime]::UtcNow - $S.PressAt).TotalMilliseconds -lt 40) { $fx = 1.05; $fy = 0.88 }
    $U.SquashT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-CNAnim $fx 1.0 220 $S.EasePress))
    $U.SquashT.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-CNAnim $fy 1.0 220 $S.EasePress))
}

# ---------------------------------------------------------------- 音效（运行时合成的短音，不含任何外部音频文件）
function New-CNTone([double]$F0, [double]$F1, [int]$Ms, [double]$Vol) {
    $rate = 22050; $n = [int]($rate * $Ms / 1000)
    $mem = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($mem)
    $ascii = [Text.Encoding]::ASCII
    $bw.Write($ascii.GetBytes('RIFF')); $bw.Write([int](36 + $n * 2)); $bw.Write($ascii.GetBytes('WAVEfmt '))
    $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1); $bw.Write([int]$rate); $bw.Write([int]($rate * 2))
    $bw.Write([int16]2); $bw.Write([int16]16); $bw.Write($ascii.GetBytes('data')); $bw.Write([int]($n * 2))
    $phase = 0.0; $twoPi = 2 * [Math]::PI
    for ($i = 0; $i -lt $n; $i++) {
        $p = $i / $n
        $phase += $twoPi * ($F0 + ($F1 - $F0) * $p) / $rate
        $amp = [Math]::Min(1.0, $i / ($rate * 0.004)) * [Math]::Pow(1 - $p, 2.4)
        $smp = ([Math]::Sin($phase) * 0.75 + [Math]::Sin($phase * 2) * 0.18) * $amp * $Vol
        $bw.Write([int16][Math]::Max(-32767, [Math]::Min(32767, $smp * 32767)))
    }
    $bw.Flush()
    return $mem.ToArray()
}
function Update-CNSounds {
    $v = [double]$Cfg.volume
    $S.Snd = @{
        press   = New-Object Media.SoundPlayer(New-Object IO.MemoryStream(, (New-CNTone 520 430 55 $v)))
        release = New-Object Media.SoundPlayer(New-Object IO.MemoryStream(, (New-CNTone 760 980 70 $v)))
    }
    foreach ($p in $S.Snd.Values) { try { $p.Load() } catch { } }
}
function Invoke-CNSound([string]$Name) {
    if ($Cfg.muted -or $RenderTest) { return }
    try { $S.Snd[$Name].Play() } catch { }
}
Update-CNSounds

# ---------------------------------------------------------------- 思考泡泡
# 打开：小圆点 → 中圆点 → 大泡依次弹出（各 0.2s，间隔 0.13s），文字 0.36s 后淡入；
# 点泡泡：文字 0.12s 淡出 → 换下一页 → 0.16s 淡入；最后一页再点就按相反顺序收起；每页停留 5 秒自动收起。
$S.Bub = @{ open = $false; pages = @(); idx = 0; hideAt = $null; hover = $false; tok = 0; countdown = $null }

function Set-CNPart($El, $Tr, [double]$Opacity, [double]$Scale, [double]$DelayMs) {
    $El.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-CNAnim $null $Opacity 200 $S.EaseCss $DelayMs))
    $Tr.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-CNAnim $null $Scale 200 $S.EaseCss $DelayMs))
    $Tr.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-CNAnim $null $Scale 200 $S.EaseCss $DelayMs))
}
function Open-CNBubbleShapes {
    $S.Bub.open = $true; $S.Bub.tok++
    $U.BubbleBox.IsHitTestVisible = $true
    Set-CNPart $U.B2 $U.B2T 1 1 0
    Set-CNPart $U.B1 $U.B1T 1 1 130
    Set-CNPart $U.BShape $U.BShapeT 1 1 260
    $U.TextBox.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-CNAnim $null 1 160 $S.EaseCss 360))
}
function Close-CNBubble {
    if (-not $S.Bub.open) { return }
    $S.Bub.open = $false; $S.Bub.tok++; $S.Bub.countdown = $null; $S.Bub.hideAt = $null
    $S.Bub.closeTok = $S.Bub.tok
    $U.TextBox.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-CNAnim $null 0 160 $S.EaseCss))
    Set-CNPart $U.BShape $U.BShapeT 0 0.7 100
    Set-CNPart $U.B1 $U.B1T 0 0.7 200
    $a = New-CNAnim $null 0 200 $S.EaseCss 300
    $a.add_Completed({ if (-not $S.Bub.open -and $S.Bub.closeTok -eq $S.Bub.tok) { $U.BubbleBox.IsHitTestVisible = $false } })
    $U.B2.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
    $U.B2T.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-CNAnim $null 0.7 200 $S.EaseCss 300))
    $U.B2T.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-CNAnim $null 0.7 200 $S.EaseCss 300))
}

function New-CNTB([string]$Text, [double]$Size, $Brush, [string]$Weight = 'Normal') {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.FontSize = $Size; $tb.Foreground = $Brush
    $tb.FontWeight = [Windows.FontWeights]::$Weight
    $tb.HorizontalAlignment = 'Center'; $tb.TextAlignment = 'Center'
    [void]$U.TextPanel.Children.Add($tb)
    return $tb
}
function Set-CNPageContent($Pg) {
    $U.TextPanel.Children.Clear()
    $S.Bub.countdown = $null
    $brown = Get-CNBrush '#FF8A5A44'
    $stroke = Get-CNBrush '#FFD97757'
    $rainbow = $null
    if ($Pg.rainbow) { $rainbow = New-CNRainbow }
    if ($Pg.rainbow -eq 'full') { $stroke = $rainbow }
    foreach ($sh in $U.BShape, $U.B1, $U.B2) { $sh.Stroke = $stroke }
    if ($Pg.kind -eq 'text') {
        # 按字数自动缩小字号，保证长句也待在泡泡里
        $len = ([string]$Pg.text).Length
        $fs = 58; if ($len -gt 30) { $fs = 46 } elseif ($len -gt 20) { $fs = 52 }
        $tb = New-CNTB $Pg.text $fs $brown 'SemiBold'
        $tb.TextWrapping = 'Wrap'; $tb.MaxWidth = 580; $tb.LineHeight = [Math]::Round($fs * 1.27)
        if ($rainbow) { $tb.Foreground = $rainbow }
        return
    }
    $lb = New-CNTB $Pg.label 66 $brown 'SemiBold'
    $amtBrush = $brown; if ($Pg.color) { $amtBrush = Get-CNBrush $Pg.color }
    $am = New-CNTB $Pg.amount 128 $amtBrush 'ExtraBold'
    $am.LineHeight = 134; $am.Margin = '0,2,0,0'
    $hint = New-CNTB '' 52 (Get-CNBrush '#FFA09D96')
    $hint.Margin = '0,9,0,0'
    if ($Pg.resets) {
        $S.Bub.countdown = @{ tb = $hint; resets = [long]$Pg.resets; pre = ''; post = '' }
        Update-CNCountdown
    } else {
        $hint.Text = [string]$Pg.hint
    }
    if ($Pg.sub) { $sub = New-CNTB ([string]$Pg.sub) 40 (Get-CNBrush '#FFB8B4AC'); $sub.Margin = '0,4,0,0' }
    if ($rainbow) { $lb.Foreground = $rainbow; $am.Foreground = $rainbow }
}
function Update-CNCountdown {
    $c = $S.Bub.countdown
    if (-not $c) { return }
    $left = $c.resets - (Get-CNNow)
    if ($left -le 0) { $c.tb.Text = $c.pre + '已重置' + $c.post; $S.Bub.countdown = $null; Test-CNAlerts }
    else { $c.tb.Text = $c.pre + (Format-CNLeft $left) + '后重置' + $c.post }
}
function Show-CNPageAt([int]$I) {
    $pg = $S.Bub.pages[$I]
    $S.Bub.idx = $I
    $ttl = 5.0; if ($pg.ttl) { $ttl = [double]$pg.ttl }
    $S.Bub.hideAt = [DateTime]::UtcNow.AddSeconds($ttl)
    if ($S.Bub.open) {
        # 淡切：0.12s 淡出 → 换内容 → 0.16s 淡入
        $S.Bub.tok++
        $S.Bub.pending = $pg; $S.Bub.pendingTok = $S.Bub.tok
        $a = New-CNAnim $null 0 120 $S.EaseCss
        $a.add_Completed({
            if ($S.Bub.open -and $S.Bub.pending -and $S.Bub.pendingTok -eq $S.Bub.tok) {
                Set-CNPageContent $S.Bub.pending
                $S.Bub.pending = $null
                $U.TextBox.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-CNAnim $null 1 160 $S.EaseCss))
            }
        })
        $U.TextBox.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
    } else {
        Set-CNPageContent $pg
        Open-CNBubbleShapes
    }
}
function Show-CNPages($Pages) {
    $S.Bub.pages = @($Pages)
    if ($S.Bub.pages.Count -eq 0) { return }
    Show-CNPageAt 0
}
function Step-CNPage {
    if (-not $S.Bub.open) { return }
    if ($S.Bub.idx + 1 -lt $S.Bub.pages.Count) { Show-CNPageAt ($S.Bub.idx + 1) } else { Close-CNBubble }
}
function Show-CNText([string]$Text, [double]$Sec = 5, $Rainbow = $null) {
    Show-CNPages @(@{ kind = 'text'; text = $Text; ttl = $Sec; rainbow = $Rainbow })
}

# ---------------------------------------------------------------- 文本格式
function Format-CNTokens($n) {
    $n = [double]$n
    if ($n -ge 1e9) { return ('{0:0.##}B' -f ($n / 1e9)) }
    if ($n -ge 1e6) { return ('{0:0.#}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0.#}K' -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}
function Format-CNLeft([long]$Sec) {
    if ($Sec -le 0) { return '马上' }
    $d = [Math]::Floor($Sec / 86400); $h = [Math]::Floor(($Sec % 86400) / 3600); $m = [Math]::Floor(($Sec % 3600) / 60)
    if ($d -gt 0 -and $h -eq 0) { return ('{0}天' -f $d) }
    if ($d -gt 0) { return ('{0}天{1}小时' -f $d, $h) }
    if ($h -gt 0) { return ('{0}小时{1}分' -f $h, $m) }
    if ($m -gt 0) { return ('{0}分钟' -f $m) }
    return ('{0}秒' -f $Sec)
}
function Format-CNAge([long]$Sec) {
    if ($Sec -lt 60) { return '刚刚' }
    if ($Sec -lt 3600) { return ('{0} 分钟前' -f [Math]::Floor($Sec / 60)) }
    if ($Sec -lt 86400) { return ('{0} 小时前' -f [Math]::Floor($Sec / 3600)) }
    return ('{0} 天前' -f [Math]::Floor($Sec / 86400))
}
function Get-CNLevelColor([double]$Rem) {
    if ($Rem -ge 50) { return '#FF8A5A44' }
    if ($Rem -ge 20) { return '#FFD0832F' }
    return '#FFD2453A'
}
$S.WinLabels = @{ five_hour = '5小时'; seven_day = '本周'; seven_day_opus = '本周 Opus '; seven_day_sonnet = '本周 Sonnet '; seven_day_oauth_apps = '本周应用'; spend_limit = '消费额度'; extra = '额外用量' }
$S.PlanNames = @{ free = 'Free'; pro = 'Pro'; max = 'Max'; team = 'Team'; enterprise = 'Enterprise'; ultra = 'Ultra' }
function Get-CNPlanName {
    if (-not $S.Plan) { return '' }
    $pn = $S.PlanNames[([string]$S.Plan).ToLowerInvariant()]
    if ($pn) { return $pn }
    return [string]$S.Plan
}

# ---------------------------------------------------------------- 泡泡内容
function Get-CNView {
    $now = Get-CNNow
    $best = $null
    $cands = @()
    if ($S.Web -and ($now - $S.Web.at) -lt 86400 -and $S.Web.windows.Count -gt 0) { $cands += @{ kind = 'web'; at = $S.Web.at; windows = $S.Web.windows; stale = 300 } }
    if ($S.Api -and ($now - $S.Api.at) -lt 86400 -and $S.Api.windows.Count -gt 0) { $cands += @{ kind = 'api'; at = $S.Api.at; windows = $S.Api.windows; stale = 300 } }
    if ($S.Bridge -and $S.Bridge.windows.Count -gt 0) { $cands += @{ kind = 'bridge'; at = $S.Bridge.captured; windows = $S.Bridge.windows; stale = 1800 } }
    foreach ($c in $cands) { if (-not $best -or $c.at -gt $best.at) { $best = $c } }
    return $best
}
function Get-CNWebErrorText($E) {
    if (-not $E) { return '' }
    switch ($E.reason) {
        'badkey' { return '保存的 sessionKey 无法解开（可能换了 Windows 用户），请重新连接。' }
        'noorg'  { return '这个账号下没有找到可用的组织。' }
        'http' {
            if ($E.cf) { return '请求被 Cloudflare 拦截了，暂时读不到 claude.ai 的数据。' }
            if ($E.code -eq 401 -or $E.code -eq 403) { return 'sessionKey 无效或已过期，右键 →「连接 claude.ai 账号」重新粘贴一下吧。' }
            if ($E.code -eq 429) { return '请求太频繁啦，过几分钟再看。' }
            return ('claude.ai 暂时读取失败（{0}）。' -f $E.code)
        }
        default { return 'claude.ai 暂时连不上，检查一下网络吧。' }
    }
}
function Get-CNQuotePage {
    $r = $S.Rand.NextDouble()
    if ($r -lt 0.005) { return @{ kind = 'text'; text = '✨ 被你发现啦！这是 0.5% 的彩蛋，今天一定会有好运的～'; rainbow = 'full'; ttl = 6 } }
    $q = $S.Quotes[$S.Rand.Next($S.Quotes.Count)]
    if ($S.Quotes.Count -gt 1) { while ($q -eq $S.LastQuote) { $q = $S.Quotes[$S.Rand.Next($S.Quotes.Count)] } }
    $S.LastQuote = $q
    $rb = $null; if ($r -lt 0.03) { $rb = 'text' }
    return @{ kind = 'text'; text = $q; rainbow = $rb; ttl = 5 }
}
function Get-CNQuotaPages {
    $pages = @()
    $now = Get-CNNow
    $v = Get-CNView
    if ($v) {
        $age = $now - $v.at
        $sub = $null; if ($age -gt $v.stale) { $sub = '数据更新于 ' + (Format-CNAge $age) }
        foreach ($w in $v.windows) {
            $used = [double]$w.used; $isReset = $false
            if ($w.resets -and $w.resets -le $now) { $used = 0; $isReset = $true }
            $rem = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - $used))
            $name = $S.WinLabels[$w.key]; if (-not $name) { $name = $w.key }
            if ($w.key -eq 'extra') {
                $pg = @{ kind = 'quota'; label = '额外用量'; amount = ('{0}%' -f [Math]::Round($used)); color = '#FF8A5A44'; hint = '本月已使用'; sub = $sub }
            } else {
                $pg = @{ kind = 'quota'; label = ($name + '剩余'); amount = ('{0}%' -f [Math]::Floor($rem)); color = (Get-CNLevelColor $rem); sub = $sub }
                if ($isReset) { $pg.hint = '已重置' }
                elseif ($w.resets) { $pg.resets = [long]$w.resets }
                else { $pg.hint = '' }
            }
            $pages += $pg
        }
    } else {
        $pages += @{ kind = 'text'; text = '还没拿到额度～开着 xiaoke-quota 插件，在 Claude 里发条消息就有啦！'; ttl = 8 }
    }
    $L = $S.Local
    if ($L -and $L.hasData -and $L.weekTokens -gt 0) {
        $pages += @{ kind = 'quota'; label = 'Claude Code 今日'; amount = (Format-CNTokens $L.todayTokens); color = '#FF8A5A44'; hint = ('tokens · 近 7 天 ' + (Format-CNTokens $L.weekTokens)) }
    }
    $pages += (Get-CNQuotePage)
    return , $pages
}
function Show-CNQuota { Show-CNPages (Get-CNQuotaPages) }

# ---------------------------------------------------------------- 数据采集（后台 runspace）
$S.Sync = [hashtable]::Synchronized(@{})
$S.Rs = [runspacefactory]::CreateRunspace()
$S.Rs.Open()
$S.CollectorPath = Join-Path $AppDir 'Collector.ps1'
$S.NextCollect = [DateTime]::UtcNow
$S.NextApi = [DateTime]::UtcNow
$S.NextWeb = [DateTime]::UtcNow
$S.LastForce = [DateTime]::MinValue

function Start-CNCollect([bool]$Force) {
    if ($S.Job) { return }
    $now = [DateTime]::UtcNow
    $allowForce = $Force -and ($now - $S.LastForce).TotalSeconds -ge 30
    if ($allowForce) { $S.LastForce = $now }
    $queryWeb = $false
    if (Test-CNWebConnected $DataDir) {
        if ($now -ge $S.NextWeb -or ($allowForce -and -not $S.WebBackoff)) { $queryWeb = $true; $S.NextWeb = $now.AddSeconds(120); $S.WebBackoff = $false }
    }
    $queryApi = $false
    if ($Cfg.useApi) {
        if ($now -ge $S.NextApi -or ($allowForce -and -not $S.ApiBackoff)) { $queryApi = $true; $S.NextApi = $now.AddSeconds(180); $S.ApiBackoff = $false }
    }
    $opts = @{ dataDir = $DataDir; claudeDir = (Get-CNClaudeDir); queryApi = $queryApi; queryWeb = $queryWeb }
    $ps = [powershell]::Create()
    $ps.Runspace = $S.Rs
    [void]$ps.AddScript('param($c, $s, $o) . $c; Get-CNUsage -State $s -Opts $o').AddArgument($S.CollectorPath).AddArgument($S.Sync).AddArgument($opts)
    $S.Job = @{ PS = $ps; H = $ps.BeginInvoke() }
    $S.NextCollect = $now.AddSeconds(60)
}
function Receive-CNCollect {
    if (-not $S.Job -or -not $S.Job.H.IsCompleted) { return }
    $job = $S.Job; $S.Job = $null
    try {
        $out = $job.PS.EndInvoke($job.H)
        if ($job.PS.Streams.Error.Count -gt 0) { Write-CNLog ('采集：' + $job.PS.Streams.Error[0].ToString()) }
        if ($out -and $out.Count -gt 0) { Update-CNData $out[$out.Count - 1] }
        if ([int]$S.CollectCount -lt 2) { Write-CNMem '采集完成' }
    } catch { Write-CNLog "采集失败：$($_.Exception.Message)" }
    finally { $job.PS.Dispose() }
    # 扫描日志会产生大量临时字符串：前两次和之后每 10 次主动回收一次，并压缩大对象堆
    $S.CollectCount = 1 + [int]$S.CollectCount
    if ($S.CollectCount -le 2 -or $S.CollectCount % 10 -eq 0) {
        [Runtime.GCSettings]::LargeObjectHeapCompactionMode = [Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    }
}
function Update-CNData($R) {
    $now = Get-CNNow
    if ($R.ContainsKey('at')) { $S.LastResultAt = $now }
    if ($R.local) { $S.Local = $R.local }
    if ($R.localError) { Write-CNLog "本地统计：$($R.localError)" }
    if ($R.bridge) { $S.Bridge = $R.bridge }
    if ($R.web) {
        if ($R.web.plan) { $S.Plan = $R.web.plan }
        if ($R.web.ok) { $S.Web = @{ windows = $R.web.windows; at = $now }; $S.WebErr = $null }
        elseif ($R.web.reason -ne 'nokey') {
            $S.WebErr = $R.web
            Write-CNLog ('claude.ai：{0} {1}{2}' -f $R.web.reason, $R.web.code, $(if ($R.web.cf) { ' cloudflare' } else { '' }))
            if ($R.web.code -eq 429) { $S.NextWeb = [DateTime]::UtcNow.AddMinutes(10); $S.WebBackoff = $true }
            elseif ($R.web.cf -or $R.web.code -eq 401 -or $R.web.code -eq 403) { $S.NextWeb = [DateTime]::UtcNow.AddMinutes(15); $S.WebBackoff = $true }
        }
    }
    if ($R.api) {
        if ($R.api.plan -and -not $S.Plan) { $S.Plan = $R.api.plan }
        if ($R.api.ok) { $S.Api = @{ windows = $R.api.windows; at = $now }; $S.ApiErr = $null }
        else {
            if ($R.api.reason -eq 'nocred') { $S.NextApi = [DateTime]::UtcNow.AddMinutes(10) }
            else {
                $S.ApiErr = $R.api
                Write-CNLog ('CLI 接口：{0} {1}' -f $R.api.reason, $R.api.code)
                if ($R.api.code -eq 429) { $S.NextApi = [DateTime]::UtcNow.AddMinutes(10); $S.ApiBackoff = $true }
                else { $S.NextApi = [DateTime]::UtcNow.AddMinutes(5) }
            }
        }
    }
    Test-CNAlerts
}
function Test-CNAlerts {
    $v = Get-CNView
    $now = Get-CNNow
    $minRem = $null
    $tip = 'Claude娘'
    $pn = Get-CNPlanName; if ($pn) { $tip += ' · ' + $pn }
    if ($v) {
        foreach ($w in $v.windows) {
            if ($w.key -eq 'five_hour' -or $w.key -eq 'seven_day') {
                $used = [double]$w.used
                if ($w.resets -and $w.resets -le $now) { $used = 0 }
                $rem = 100 - $used
                if ($null -eq $minRem -or $rem -lt $minRem) { $minRem = $rem }
                $tip += (' · {0}剩 {1}%' -f $S.WinLabels[$w.key], [Math]::Floor([Math]::Max(0, $rem)))
            }
        }
    }
    if ($S.Tray) { try { if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }; $S.Tray.Text = $tip } catch { } }
    $S.Worried = ($null -ne $minRem -and $minRem -lt 20)
    if ($null -ne $minRem -and $null -ne $S.PrevMinRem -and -not $RenderTest) {
        if ($S.PrevMinRem -ge 20 -and $minRem -lt 20) { Show-CNText ('呜…额度只剩 {0}% 了，省着点用哦。' -f [Math]::Floor($minRem)) 8 }
        elseif ($S.PrevMinRem -lt 50 -and $minRem -ge 95) { Show-CNText '额度刷新啦～又可以一起大干一场了！' 6 }
    }
    if ($null -ne $minRem) { $S.PrevMinRem = $minRem }
    Update-CNExpression
}
function Update-CNBridgeQuick {
    try {
        $f = Get-CNBridgeFile $DataDir   # 可能在 Claude App 的重定向目录里，见 Collector.ps1
        if (-not $f) { return }
        $key = $f.FullName + '|' + $f.LastWriteTimeUtc.Ticks
        if ($S.BridgeKey -eq $key) { return }
        $b = Read-CNBridge $DataDir   # 正在写入时可能读到半截：解析失败就等下一秒再读
        $S.BridgeKey = $key
        if ($b) { Update-CNData @{ bridge = $b } }
    } catch { }
}

# ---------------------------------------------------------------- 显示/隐藏、缩放、模式
function Set-CNScale([double]$Scale) {
    $Scale = [Math]::Round([Math]::Max(0.6, [Math]::Min(2.5, $Scale)), 2)
    $oldW = $window.Width; $oldH = $window.Height
    $Cfg.scale = $Scale
    Set-CNLayout $Scale
    if ($oldW -and -not [double]::IsNaN($oldW)) {
        # 以小克所在的下角为锚点缩放（未翻转时右下角，翻转时左下角）
        if ($U.FlipT.ScaleX -gt 0) { $window.Left += ($oldW - $window.Width) }
        $window.Top += ($oldH - $window.Height)
    }
    if ($Cfg.mode -eq 'desktop' -and $window.IsLoaded) { Repair-CNPosition $false; Save-CNPosition }
    $S.ReloadAt = [DateTime]::UtcNow.AddMilliseconds(450)
    Request-CNSave
}
function Save-CNPosition {
    if ($Cfg.mode -eq 'desktop') { $Cfg.left = [Math]::Round($window.Left, 1); $Cfg.top = [Math]::Round($window.Top, 1) }
    Request-CNSave
}
function Set-CNMode([string]$Mode) {
    $Cfg.mode = $Mode
    if ($Mode -eq 'desktop') {
        $window.Topmost = [bool]$Cfg.topmost
        if ($null -ne $Cfg.left -and $null -ne $Cfg.top) { $window.Left = [double]$Cfg.left; $window.Top = [double]$Cfg.top; Repair-CNPosition $false } else { Set-CNDefaultPosition }
        if (-not $S.UserHidden) { $window.Visibility = 'Visible' }
        Update-CNFacing
        $S.FollowTimer.Stop()
    } else {
        $window.Topmost = $false
        $S.ClaudeHwnd = [IntPtr]::Zero; $S.NextFind = [DateTime]::MinValue
        $S.FollowTimer.Start()
    }
    Request-CNSave
}
function Show-CNWindow {
    $S.UserHidden = $false
    if ($Cfg.mode -eq 'desktop') { $window.Visibility = 'Visible' }
    if (-not $window.IsVisible -and $Cfg.mode -eq 'desktop') { $window.Show() }
    if ($S.Frames) { $S.AnimTimer.Start() }
    $S.NextCollect = [DateTime]::UtcNow
}
function Hide-CNWindow {
    $S.UserHidden = $true
    Close-CNBubble
    $window.Visibility = 'Hidden'
    $S.AnimTimer.Stop()
}

# ---------------------------------------------------------------- 跟随 Claude 桌面 App 窗口
$S.ClaudeHwnd = [IntPtr]::Zero; $S.NextFind = [DateTime]::MinValue
function Find-CNClaudeWindow {
    foreach ($p in [Diagnostics.Process]::GetProcessesByName('claude')) {
        try { if ($p.MainWindowHandle -ne [IntPtr]::Zero -and $p.MainWindowTitle -like 'Claude*') { return $p.MainWindowHandle } } catch { }
    }
    return [IntPtr]::Zero
}
function Get-CNClaudeRect {
    $h = $S.ClaudeHwnd
    if ($h -eq [IntPtr]::Zero -or -not [ClaudeNiang.Win32]::IsWindow($h)) {
        if ([DateTime]::UtcNow -ge $S.NextFind) {
            $S.ClaudeHwnd = Find-CNClaudeWindow
            $S.NextFind = [DateTime]::UtcNow.AddSeconds(1.5)
            $h = $S.ClaudeHwnd
        }
    }
    if ($h -eq [IntPtr]::Zero) { return $null }
    if (-not [ClaudeNiang.Win32]::IsWindowVisible($h) -or [ClaudeNiang.Win32]::IsIconic($h)) { return $null }
    $r = New-Object ClaudeNiang.Win32+RECT
    if (-not [ClaudeNiang.Win32]::GetVisibleRect($h, [ref]$r)) { return $null }
    $d = Get-CNDpi
    return @{ L = $r.Left / $d; T = $r.Top / $d; R = $r.Right / $d; B = $r.Bottom / $d }
}
$S.FollowTimer = New-Object Windows.Threading.DispatcherTimer
$S.FollowTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$S.FollowTimer.add_Tick({
    try {
        if ($Cfg.mode -ne 'follow' -or $S.UserHidden -or $S.Dragging -or -not $S.NativeOk) { return }
        $rc = Get-CNClaudeRect
        if (-not $rc) {
            if ($window.Visibility -eq 'Visible') { Close-CNBubble; $window.Visibility = 'Hidden'; $S.AnimTimer.Stop() }
            return
        }
        $l = $rc.R - [double]$Cfg.followDx - $window.Width
        $t = $rc.B - [double]$Cfg.followDy - $window.Height
        if ([Math]::Abs($window.Left - $l) -gt 0.5) { $window.Left = $l }
        if ([Math]::Abs($window.Top - $t) -gt 0.5) { $window.Top = $t }
        if ($window.Visibility -ne 'Visible') {
            $window.Visibility = 'Visible'
            if ($S.Frames) { $S.AnimTimer.Start() }
            Update-CNFacing
            Write-CNLog ('跟随：Claude 窗口 {0:N0},{1:N0}-{2:N0},{3:N0}；挂件 {4:N0},{5:N0} {6:N0}x{7:N0}' -f $rc.L, $rc.T, $rc.R, $rc.B, $window.Left, $window.Top, $window.Width, $window.Height)
        }
        if ($S.Hwnd) { [ClaudeNiang.Win32]::PlaceAbove($S.Hwnd, $S.ClaudeHwnd) }
    } catch { }
})

# ---------------------------------------------------------------- 鼠标交互
# 拖动自己实现（捕获鼠标 + 手动移动窗口），不用 DragMove：
# DragMove 会进入阻塞的系统拖动循环，期间 WPF 动画时钟停住，按下时的压扁就看不到了。
function Get-CNCursorDip {
    $pt = [Windows.Forms.Cursor]::Position
    $d = Get-CNDpi
    return @{ X = $pt.X / $d; Y = $pt.Y / $d }
}
function Complete-CNPress([bool]$AsClick) {
    $pr = $S.Press
    if (-not $pr) { return }
    $S.Press = $null
    $S.Dragging = $false
    Invoke-CNRelease; Invoke-CNSound 'release'
    if (-not $pr.moved) {
        if ($AsClick) {
            # 点小克：从第一页开始显示额度
            Show-CNQuota
            if (-not $S.LastResultAt -or ((Get-CNNow) - $S.LastResultAt) -gt 30) { Start-CNCollect $true }
        }
        return
    }
    if ($Cfg.mode -eq 'follow') {
        $rc = Get-CNClaudeRect
        if ($rc) {
            $Cfg.followDx = [Math]::Round($rc.R - $window.Left - $window.Width, 1)
            $Cfg.followDy = [Math]::Round($rc.B - $window.Top - $window.Height, 1)
            Request-CNSave
        }
    } else {
        Repair-CNPosition $true
        Save-CNPosition
    }
    Update-CNFacing
}
$U.CharImg.add_MouseLeftButtonDown({
    try {
        $_.Handled = $true
        $S.Press = @{ start = (Get-CNCursorDip); left = $window.Left; top = $window.Top; moved = $false }
        Invoke-CNPress; Invoke-CNSound 'press'
        [void]$U.CharImg.CaptureMouse()
    } catch { Write-CNLog "按下处理：$($_.Exception.Message)" }
})
$U.CharImg.add_MouseMove({
    try {
        $pr = $S.Press
        if (-not $pr) { return }
        $p = Get-CNCursorDip
        $dx = $p.X - $pr.start.X; $dy = $p.Y - $pr.start.Y
        if (-not $pr.moved) {
            if ([Math]::Abs($dx) + [Math]::Abs($dy) -lt 5) { return }
            $pr.moved = $true; $S.Dragging = $true
        }
        $window.Left = [Math]::Round($pr.left + $dx)
        $window.Top = [Math]::Round($pr.top + $dy)
    } catch { }
})
$U.CharImg.add_MouseLeftButtonUp({
    try {
        if (-not $S.Press) { return }
        $_.Handled = $true
        $pr = $S.Press
        Complete-CNPress $true
        $U.CharImg.ReleaseMouseCapture()
    } catch { $S.Press = $null; $S.Dragging = $false; Write-CNLog "松开处理：$($_.Exception.Message)" }
})
# 鼠标捕获被系统收走（切换窗口等）时，当作松开但不算点击
$U.CharImg.add_LostMouseCapture({ try { Complete-CNPress $false } catch { } })
$U.CharImg.add_MouseWheel({
    try {
        if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) {
            $_.Handled = $true
            $step = 0.1; if ($_.Delta -lt 0) { $step = -0.1 }
            Set-CNScale ([double]$Cfg.scale + $step)
        }
    } catch { }
})
# 点泡泡：下一页；最后一页再点就收起
$U.BubbleBox.add_MouseLeftButtonUp({ try { $_.Handled = $true; Step-CNPage } catch { } })
$U.BubbleBox.add_MouseEnter({ $S.Bub.hover = $true })
$U.BubbleBox.add_MouseLeave({
    $S.Bub.hover = $false
    if ($S.Bub.hideAt -and $S.Bub.hideAt -lt [DateTime]::UtcNow.AddSeconds(2)) { $S.Bub.hideAt = [DateTime]::UtcNow.AddSeconds(2) }
})

# ---------------------------------------------------------------- 右键菜单
function New-CNItem([string]$Header, [scriptblock]$OnClick = $null, $Checked = $null, $Tag = $null) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $Header
    if ($null -ne $Checked) { $mi.IsChecked = [bool]$Checked }
    if ($null -ne $Tag) { $mi.Tag = $Tag }
    if ($OnClick) { $mi.add_Click($OnClick) }
    return $mi
}
function Add-CNSep($Menu) { [void]$Menu.Items.Add((New-Object Windows.Controls.Separator)) }
function Show-CNMessage([string]$Text, [string]$Icon = 'Information') {
    [void][Windows.MessageBox]::Show($Text, 'Claude娘', 'OK', $Icon)
}
function Invoke-CNBridgeInstall {
    $r = Install-CNBridge $AppDir
    switch ($r.code) {
        'installed' { Show-CNText '状态栏桥接装好啦！以后用 Claude Code 时，我也能拿到最新的额度。' 6 }
        'already'   { Show-CNText '状态栏桥接已经装好啦～' 4 }
        'exists'    {
            $p = (Join-Path $DataDir 'statusline-bridge.ps1') -replace '\\', '/'
            Show-CNMessage ("你的 Claude Code 已经配置了自定义状态栏，为了不覆盖它，我没有修改设置。`n`n现有命令：`n$($r.existing)`n`n如需同时使用，可以让你的状态栏脚本把收到的 JSON 再转交给：`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$p`"")
        }
        default     { Show-CNMessage ("安装失败（{0}）。请检查 ~/.claude/settings.json 是否是合法的 JSON。" -f $r.code) 'Warning' }
    }
}
function Update-CNMenu($Menu) {
    $Menu.Items.Clear()
    [void]$Menu.Items.Add((New-CNItem '查看额度' { Start-CNCollect $true; Show-CNQuota }))
    [void]$Menu.Items.Add((New-CNItem '说句话' { Show-CNPages @(Get-CNQuotePage) }))
    Add-CNSep $Menu

    $size = New-CNItem '大小'
    foreach ($v in 0.6, 0.8, 1.0, 1.4, 2.0, 2.5) {
        [void]$size.Items.Add((New-CNItem ('{0}%' -f [int]($v * 100)) { Set-CNScale ([double]$this.Tag) } ([Math]::Abs([double]$Cfg.scale - $v) -lt 0.01) $v))
    }
    Add-CNSep $size
    $hint = New-CNItem '按住 Ctrl 滚动滚轮可微调'; $hint.IsEnabled = $false
    [void]$size.Items.Add($hint)
    [void]$Menu.Items.Add($size)

    $pos = New-CNItem '显示与位置'
    [void]$pos.Items.Add((New-CNItem '桌面模式（自由拖动）' { Set-CNMode 'desktop' } ($Cfg.mode -eq 'desktop')))
    $fi = New-CNItem '跟随 Claude 桌面 App 窗口' { Set-CNMode 'follow' } ($Cfg.mode -eq 'follow')
    if (-not $S.NativeOk) { $fi.IsEnabled = $false }
    [void]$pos.Items.Add($fi)
    Add-CNSep $pos
    $tp = New-CNItem '置顶显示（桌面模式）' { $Cfg.topmost = -not [bool]$Cfg.topmost; if ($Cfg.mode -eq 'desktop') { $window.Topmost = [bool]$Cfg.topmost }; Request-CNSave } ([bool]$Cfg.topmost)
    if ($Cfg.mode -ne 'desktop') { $tp.IsEnabled = $false }
    [void]$pos.Items.Add($tp)
    [void]$pos.Items.Add((New-CNItem '重置位置' {
        if ($Cfg.mode -eq 'desktop') { Set-CNDefaultPosition; Save-CNPosition; Update-CNFacing } else { $Cfg.followDx = 0.0; $Cfg.followDy = 0.0; Request-CNSave }
    }))
    [void]$Menu.Items.Add($pos)

    $snd = New-CNItem '声音'
    [void]$snd.Items.Add((New-CNItem '静音' { $Cfg.muted = -not [bool]$Cfg.muted; Request-CNSave } ([bool]$Cfg.muted)))
    Add-CNSep $snd
    foreach ($pair in @(@('小', 0.3), @('中', 0.55), @('大', 0.85))) {
        [void]$snd.Items.Add((New-CNItem ('音量：' + $pair[0]) { $Cfg.volume = [double]$this.Tag; $Cfg.muted = $false; Update-CNSounds; Invoke-CNSound 'release'; Request-CNSave } ([Math]::Abs([double]$Cfg.volume - $pair[1]) -lt 0.01) $pair[1]))
    }
    [void]$Menu.Items.Add($snd)

    $aq = New-CNItem '自动说话'
    foreach ($m in 0, 5, 15, 30) {
        $label = '关闭'; if ($m -gt 0) { $label = "每 $m 分钟" }
        [void]$aq.Items.Add((New-CNItem $label { $Cfg.autoQuoteMin = [int]$this.Tag; $S.NextAutoQuote = [DateTime]::UtcNow.AddMinutes([Math]::Max(1, [int]$this.Tag)); Request-CNSave } ([int]$Cfg.autoQuoteMin -eq $m) $m))
    }
    [void]$Menu.Items.Add($aq)

    $ds = New-CNItem '其他数据来源'
    [void]$ds.Items.Add((New-CNItem 'Claude Code：读取 CLI 登录的用量接口' { $Cfg.useApi = -not [bool]$Cfg.useApi; $S.ApiErr = $null; $S.NextApi = [DateTime]::UtcNow; Request-CNSave; Start-CNCollect $true } ([bool]$Cfg.useApi)))
    if (Test-CNBridgeInstalled) {
        [void]$ds.Items.Add((New-CNItem 'Claude Code：移除状态栏桥接' {
            $r = Uninstall-CNBridge
            if ($r.ok) { Show-CNText '状态栏桥接已移除～' 4 } else { Show-CNMessage '移除失败，请手动编辑 ~/.claude/settings.json。' 'Warning' }
        }))
    } else {
        [void]$ds.Items.Add((New-CNItem 'Claude Code：安装状态栏桥接' { Invoke-CNBridgeInstall }))
    }
    Add-CNSep $ds
    [void]$ds.Items.Add((New-CNItem '打开数据目录' { Start-Process explorer.exe -ArgumentList ('"' + $DataDir + '"') }))
    [void]$Menu.Items.Add($ds)

    $qm = New-CNItem '语录'
    [void]$qm.Items.Add((New-CNItem '编辑语录…' { Start-Process notepad.exe -ArgumentList ('"' + $S.QuotesPath + '"') }))
    [void]$qm.Items.Add((New-CNItem '重新加载语录' { Import-CNQuotes; Show-CNText ('已加载 {0} 条语录～' -f $S.Quotes.Count) 4 }))
    [void]$Menu.Items.Add($qm)

    [void]$Menu.Items.Add((New-CNItem '省内存模式（静态立绘）' {
        $Cfg.lowMemory = -not [bool]$Cfg.lowMemory; Request-CNSave
        if ($Cfg.lowMemory) { Show-CNStaticChar; [GC]::Collect() } else { $S.FrameSet = ''; Update-CNExpression }
    } ([bool]$Cfg.lowMemory)))
    [void]$Menu.Items.Add((New-CNItem '开机自启' { Set-CNAutostart (-not (Test-CNAutostart)) $AppDir } (Test-CNAutostart)))
    Add-CNSep $Menu
    [void]$Menu.Items.Add((New-CNItem '隐藏（托盘图标可唤回）' { Hide-CNWindow }))
    [void]$Menu.Items.Add((New-CNItem ('关于 Claude娘 v' + $S.Version) {
        Show-CNMessage ("Claude娘 v$($S.Version)`n陪你看 Claude 剩余额度的桌面看板娘。`n`n作者：liangcka（github.com/liangcka/xiaoke-quota）`n代码许可：PolyForm Noncommercial 1.0.0，禁止商用。`n`n角色「小克」立绘与动画：aklnaaw/dsh-xiaoke-widget（动画制作 AirsEDA），CC BY-NC-SA 4.0，仅限非商业使用。`n泡泡轮廓与按压参数取自 dsh-xiaoke-widget（MIT），整体灵感来自 GPT-Niang。`n`n数据目录：$DataDir")
    }))
    [void]$Menu.Items.Add((New-CNItem '退出' { Exit-CN }))
}
$S.Menu = New-Object Windows.Controls.ContextMenu
$S.Menu.FontFamily = 'Microsoft YaHei UI'
$U.CharImg.ContextMenu = $S.Menu
$U.CharImg.add_ContextMenuOpening({ try { Update-CNMenu $S.Menu } catch { Write-CNLog "菜单：$($_.Exception.Message)" } })

# ---------------------------------------------------------------- 托盘图标
function New-CNTray {
    try {
        [Windows.Forms.Application]::EnableVisualStyles()
        $src = New-Object Drawing.Bitmap((Join-Path $AppDir 'assets\xiaoke\icon.png'))
        $bmp = New-Object Drawing.Bitmap(32, 32)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'AntiAlias'
        $g.DrawImage($src, 0, 0, 32, 32); $g.Dispose(); $src.Dispose()
        $tray = New-Object Windows.Forms.NotifyIcon
        $tray.Icon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
        $tray.Text = 'Claude娘'
        $cms = New-Object Windows.Forms.ContextMenuStrip
        [void]$cms.Items.Add('显示 / 隐藏', $null, { if ($S.UserHidden -or -not $window.IsVisible) { Show-CNWindow } else { Hide-CNWindow } })
        [void]$cms.Items.Add('查看额度', $null, { Show-CNWindow; Start-CNCollect $true; Show-CNQuota })
        [void]$cms.Items.Add('重置位置', $null, { Show-CNWindow; Set-CNMode 'desktop'; Set-CNDefaultPosition; Save-CNPosition; Update-CNFacing })
        [void]$cms.Items.Add('-')
        [void]$cms.Items.Add('退出', $null, { Exit-CN })
        $tray.ContextMenuStrip = $cms
        $tray.add_MouseDoubleClick({ if ($S.UserHidden -or -not $window.IsVisible) { Show-CNWindow } else { Hide-CNWindow } })
        $tray.Visible = $true
        $S.Tray = $tray
    } catch { Write-CNLog "托盘图标：$($_.Exception.Message)" }
}

# ---------------------------------------------------------------- 主循环
function Exit-CN {
    if ($S.Exiting) { return }
    $S.Exiting = $true
    Save-CNConfig
    try { $S.Tray.Visible = $false; $S.Tray.Dispose() } catch { }
    try { $S.UiTimer.Stop(); $S.AnimTimer.Stop(); $S.FollowTimer.Stop() } catch { }
    try { $window.Close() } catch { }
    try { [Windows.Application]::Current.Shutdown() } catch { }
}
$S.UiTimer = New-Object Windows.Threading.DispatcherTimer
$S.UiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$S.LastSec = [DateTime]::MinValue
$S.UiTimer.add_Tick({
    try {
        Receive-CNCollect
        $now = [DateTime]::UtcNow
        if ($S.ShowEvent -and $S.ShowEvent.WaitOne(0)) { Show-CNWindow; Show-CNText '我在这儿呢～' 3 }
        if ($S.ExitEvent -and $S.ExitEvent.WaitOne(0)) { Exit-CN; return }
        $visible = $window.IsVisible -and $window.Visibility -eq 'Visible'
        if ($visible -and -not $S.Job -and $now -ge $S.NextCollect) { Start-CNCollect $false }
        if ($S.Bub.open -and $S.Bub.hideAt -and $now -ge $S.Bub.hideAt -and -not $S.Bub.hover) { Close-CNBubble }
        if (($now - $S.LastSec).TotalMilliseconds -ge 1000) {
            $S.LastSec = $now
            if ($S.Bub.open) { Update-CNCountdown }
            Update-CNBridgeQuick
            if ($S.SaveDue -and $now -ge $S.SaveDue) { $S.SaveDue = $null; Save-CNConfig }
            if ($S.ReloadAt -and $now -ge $S.ReloadAt) {
                $S.ReloadAt = $null
                if ($S.CharMode -eq 'anim' -or $S.Loader) { $set = $S.FrameSet; if ($S.Loader) { $set = $S.Loader.set }; if (-not $set) { $set = 'normal' }; Start-CNCharLoad $set }
            }
            if ([int]$Cfg.autoQuoteMin -gt 0 -and $visible -and -not $S.Bub.open) {
                if (-not $S.NextAutoQuote) { $S.NextAutoQuote = $now.AddMinutes([int]$Cfg.autoQuoteMin) }
                elseif ($now -ge $S.NextAutoQuote) { $S.NextAutoQuote = $now.AddMinutes([int]$Cfg.autoQuoteMin); Show-CNPages @(Get-CNQuotePage) }
            }
        }
    } catch { Write-CNLog "定时器：$($_.Exception.Message)" }
})
function Get-CNGreeting {
    $h = (Get-Date).Hour
    if ($h -lt 5) { return '这么晚还没睡呀…要注意身体哦。' }
    if ($h -lt 11) { return '早上好！今天也一起加油吧～' }
    if ($h -lt 14) { return '中午好～记得按时吃饭哦。' }
    if ($h -lt 18) { return '下午好！点我就能看剩余额度哦～' }
    if ($h -lt 23) { return '晚上好～今天也辛苦啦。' }
    return '快到半夜了，早点休息吧。'
}

# ---------------------------------------------------------------- 开发用：渲染预览图
if ($RenderTest) {
    Set-CNLayout $RenderScale
    $set = 'normal'; if ($RenderState -eq 'cry') { $set = 'cry' }
    if ($S.NativeOk -and $S.AnimMeta) {
        $px = Get-CNFramePx
        $file = $S.AnimMeta.sets.$set.file
        if ($px -gt 384 -and $S.AnimMeta.hd) { $file = $S.AnimMeta.hd.$set }
        $wf = New-Object ClaudeNiang.WebpFrames((Join-Path $AppDir ('assets\xiaoke\' + $file)), $false)
        $U.CharImg.Source = $wf.GetFrame(0, 0, 0, $wf.SourceWidth, $wf.SourceWidth, $px, $px)
        $wf.Dispose()
    } else { Show-CNStaticChar }
    $now = Get-CNNow
    $S.Local = @{ hasData = $true; weekTokens = 38200000; todayTokens = 6500000 }
    $pg = $null
    switch ($RenderState) {
        'quota'  { $S.Plan = 'max'; $S.Web = @{ at = $now - 20; windows = @(@{ key = 'five_hour'; used = 23.5; resets = $now + 7800 }, @{ key = 'seven_day'; used = 61; resets = $now + 3 * 86400 }) }; $pg = (Get-CNQuotaPages)[0] }
        'week'   { $S.Plan = 'max'; $S.Web = @{ at = $now - 20; windows = @(@{ key = 'five_hour'; used = 23.5; resets = $now + 7800 }, @{ key = 'seven_day'; used = 61; resets = $now + 3 * 86400 + 4000 }) }; $pg = (Get-CNQuotaPages)[1] }
        'cry'    { $S.Web = @{ at = $now - 900; windows = @(@{ key = 'five_hour'; used = 91; resets = $now + 2400 }) }; $pg = (Get-CNQuotaPages)[0] }
        'nodata' { $S.Local = $null; $pg = (Get-CNQuotaPages)[0] }
        'quote'  { $pg = @{ kind = 'text'; text = '先读代码，再下结论，这是我的原则哦。' } }
        'flip'   { $pg = @{ kind = 'text'; text = '我会一直朝向屏幕里面哦～' }; $U.FlipT.ScaleX = -1; $U.TextFlipT.ScaleX = -1 }
    }
    Set-CNPageContent $pg
    foreach ($e in $U.BShape, $U.B1, $U.B2, $U.TextBox) { $e.Opacity = 1 }
    foreach ($t in $U.BShapeT, $U.B1T, $U.B2T) { $t.ScaleX = 1; $t.ScaleY = 1 }
    $U.Root.Background = Get-CNBrush '#FFDCE3EA'
    $W = [double]$U.Root.Width
    $U.Root.Measure((New-Object Windows.Size($W, $W)))
    $U.Root.Arrange((New-Object Windows.Rect(0, 0, $W, $W)))
    $U.Root.UpdateLayout()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$W, [int]$W, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($U.Root)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($RenderOut); $enc.Save($fs); $fs.Dispose()
    try { $S.Rs.Close() } catch { }
    return
}

# ---------------------------------------------------------------- 启动
$app = New-Object Windows.Application
$app.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown
$app.add_DispatcherUnhandledException({ Write-CNLog ("未处理异常：" + $_.Exception.ToString()); $_.Handled = $true })

$window.add_SourceInitialized({
    try {
        $S.Hwnd = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
        if ($S.NativeOk) { [ClaudeNiang.Win32]::AddExStyle($S.Hwnd, [ClaudeNiang.Win32]::WS_EX_TOOLWINDOW -bor [ClaudeNiang.Win32]::WS_EX_NOACTIVATE) }
    } catch { }
})
$window.add_Closing({ if (-not $S.Exiting) { $_.Cancel = $true; Hide-CNWindow } })

Set-CNLayout ([double]$Cfg.scale)
if ($null -ne $Cfg.left -and $null -ne $Cfg.top) { $window.Left = [double]$Cfg.left; $window.Top = [double]$Cfg.top } else { $window.Left = -10000; $window.Top = -10000 }

$window.Show()
Write-CNMem '窗口已显示'
if ($null -eq $Cfg.left -or $null -eq $Cfg.top) { Set-CNDefaultPosition } else { Repair-CNPosition $false }
Set-CNMode $Cfg.mode
New-CNTray
Start-CNCharLoad 'normal'
$S.UiTimer.Start()
Start-CNCollect $false
$S.GreetTimer = New-Object Windows.Threading.DispatcherTimer
$S.GreetTimer.Interval = [TimeSpan]::FromMilliseconds(1600)
$S.GreetTimer.add_Tick({
    $S.GreetTimer.Stop()
    if (-not $S.Bub.open) {
        Show-CNText (Get-CNGreeting) 5
    }
})
$S.GreetTimer.Start()

if ($SelfTest -gt 0) {
    $S.SelfSteps = New-Object 'System.Collections.Generic.Queue[scriptblock]'
    foreach ($sb in @(
        { Show-CNQuota; Write-CNLog ("自检：泡泡页数 {0}" -f $S.Bub.pages.Count) },
        { Step-CNPage },
        { Step-CNPage },
        { Update-CNMenu $S.Menu; Write-CNLog ("自检：菜单项 {0}" -f $S.Menu.Items.Count) },
        { Invoke-CNPress },
        { Invoke-CNRelease },
        { Write-CNLog ("自检：按压恢复 scaleX={0:N3} scaleY={1:N3}" -f $U.SquashT.ScaleX, $U.SquashT.ScaleY) },
        { Set-CNScale 1.4 },
        { Set-CNScale 1.0 },
        { $S.Worried = $true; Update-CNExpression },
        { $S.Worried = $false; Update-CNExpression },
        { Set-CNMode 'follow' },
        { Write-CNLog ("自检：跟随模式 visible={0} claudeHwnd={1}" -f $window.Visibility, $S.ClaudeHwnd); Set-CNMode 'desktop' },
        { Close-CNBubble },
        { Write-CNLog ("自检：数据 local={0} web={1} webErr={2} bridge={3} api={4} mode={5} frames={6} bubbleOpen={7}" -f [bool]$S.Local, [bool]$S.Web, $(if ($S.WebErr) { $S.WebErr.reason } else { '' }), [bool]$S.Bridge, [bool]$S.Api, $S.CharMode, $(if ($S.Frames) { $S.Frames.Count } else { 0 }), $S.Bub.open) }
    )) { $S.SelfSteps.Enqueue($sb) }
    $S.SelfTimer = New-Object Windows.Threading.DispatcherTimer
    $S.SelfTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(500, $SelfTest * 1000 / 17))
    $S.SelfTimer.add_Tick({
        try {
            if ($S.SelfSteps.Count -gt 0) { & ($S.SelfSteps.Dequeue()) }
            else {
                $S.SelfTimer.Stop()
                Write-CNLog ("自检完成：工作集 {0:N0} MB" -f ([Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB))
                Exit-CN
            }
        } catch { Write-CNLog "自检步骤失败：$($_.Exception.Message)" }
    })
    $S.SelfTimer.Start()
}

[void]$app.Run()
try { $S.Rs.Close() } catch { }
try { $S.Mutex.ReleaseMutex() } catch { }
Write-CNLog '退出'
