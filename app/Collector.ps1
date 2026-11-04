# Collector.ps1 —— Claude娘 数据采集
# 在后台 runspace 中运行，也会被主界面 dot-source 以复用函数。
# 数据来源：
#   1. claude.ai 账号  用户粘贴的 sessionKey → claude.ai/api/organizations/{id}/usage（与桌面 App「设置 → 用量」同一份数据，只读）
#   2. 官方用量接口    ~/.claude/.credentials.json 中 Claude Code CLI 登录令牌 → api.anthropic.com/api/oauth/usage（只读）
#   3. 状态栏桥接      Claude Code 状态栏传入的 rate_limits（官方字段），由 statusline-bridge.ps1 写入 bridge.json
#   4. 本地日志统计    ~/.claude/projects/**/*.jsonl 中每条回复的 usage 字段（只读取 token 数和时间，不读内容）
Set-StrictMode -Off

function Get-CNClaudeDir {
    if ($env:CLAUDE_CONFIG_DIR -and (Test-Path -LiteralPath $env:CLAUDE_CONFIG_DIR)) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-CNNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function ConvertTo-CNEpoch($v) {
    if ($null -eq $v) { return $null }
    $d = $null
    if ($v -is [string]) {
        if ($v.Trim() -eq '') { return $null }
        if ($v -match '^\d+(\.\d+)?$') { $d = [double]$v }
        else {
            try { return [DateTimeOffset]::Parse($v, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() } catch { return $null }
        }
    }
    elseif ($v -is [datetime]) { return ([DateTimeOffset]$v.ToUniversalTime()).ToUnixTimeSeconds() }
    else { try { $d = [double]$v } catch { return $null } }
    if ($d -gt 1e12) { $d = $d / 1000 }   # 毫秒 → 秒
    return [long]$d
}

# ---------------------------------------------------------------- 本地日志扫描

function Initialize-CNScanState($State) {
    if ($State.ContainsKey('files')) { return }
    $State.files   = @{}
    $State.entries = New-Object 'System.Collections.Generic.List[object]'
    $State.seen    = New-Object 'System.Collections.Generic.HashSet[string]'
    $opt = [Text.RegularExpressions.RegexOptions]::Compiled
    $rtl = $opt -bor [Text.RegularExpressions.RegexOptions]::RightToLeft
    $State.rx = @{
        usage = New-Object regex('(?<!\\)"usage":\{', $rtl)
        ts    = New-Object regex('(?<!\\)"timestamp":"([^"]+)"', $rtl)
        id    = New-Object regex('(?<!\\)"id":"(msg_[^"]+)"', $opt)
        req   = New-Object regex('(?<!\\)"requestId":"([^"]+)"', $opt)
        model = New-Object regex('(?<!\\)"model":"([^"]+)"', $opt)
        inp   = New-Object regex('(?<!\\)"input_tokens":(\d+)', $opt)
        out   = New-Object regex('(?<!\\)"output_tokens":(\d+)', $opt)
        cw    = New-Object regex('(?<!\\)"cache_creation_input_tokens":(\d+)', $opt)
        cr    = New-Object regex('(?<!\\)"cache_read_input_tokens":(\d+)', $opt)
    }
}

function Add-CNLine($State, [string]$line) {
    if ($line.Length -lt 60) { return }
    if ($line.IndexOf('"type":"assistant"', [StringComparison]::Ordinal) -lt 0) { return }
    $rx = $State.rx
    $um = $rx.usage.Match($line)
    if (-not $um.Success) { return }
    $u0 = $um.Index
    $mi = $rx.inp.Match($line, $u0)
    $mo = $rx.out.Match($line, $u0)
    if (-not $mi.Success -and -not $mo.Success) { return }
    $model = ''
    $mm = $rx.model.Match($line)
    if ($mm.Success) { $model = $mm.Groups[1].Value }
    if ($model -eq '<synthetic>') { return }
    $tm = $rx.ts.Match($line)
    if (-not $tm.Success) { return }
    try { $t = [DateTimeOffset]::Parse($tm.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() } catch { return }

    $inp = 0L; $out = 0L; $cw = 0L; $cr = 0L
    if ($mi.Success) { $inp = [long]$mi.Groups[1].Value }
    if ($mo.Success) { $out = [long]$mo.Groups[1].Value }
    $m = $rx.cw.Match($line, $u0); if ($m.Success) { $cw = [long]$m.Groups[1].Value }
    $m = $rx.cr.Match($line, $u0); if ($m.Success) { $cr = [long]$m.Groups[1].Value }

    $id = ''; $req = ''
    $m = $rx.id.Match($line);  if ($m.Success) { $id = $m.Groups[1].Value }
    $m = $rx.req.Match($line); if ($m.Success) { $req = $m.Groups[1].Value }
    if ($id -ne '') { $key = $id + '|' + $req } else { $key = "$t|$inp|$out|$cw|$cr" }
    if (-not $State.seen.Add($key)) { return }   # 同一条回复会被分段写入多行，只记一次

    $fam = 'other'
    if ($model -match 'opus') { $fam = 'opus' } elseif ($model -match 'sonnet') { $fam = 'sonnet' } elseif ($model -match 'haiku') { $fam = 'haiku' } elseif ($model -match 'fable') { $fam = 'fable' }
    $State.entries.Add([pscustomobject]@{ t = $t; inp = $inp; out = $out; cw = $cw; cr = $cr; tot = ($inp + $out + $cw + $cr); fam = $fam; key = $key })
}

function Read-CNJsonlFile($State, [string]$path, [long]$len) {
    $info = $State.files[$path]
    if ($null -eq $info) { $info = @{ offset = [long]0 }; $State.files[$path] = $info }
    if ($len -lt $info.offset) { $info.offset = [long]0 }   # 文件被截断/重写
    if ($len -eq $info.offset) { return }
    $fs = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        [void]$fs.Seek($info.offset, [IO.SeekOrigin]::Begin)
        $pos = [long]$info.offset
        $committed = [long]$info.offset
        $chunk = 4MB
        $buf = New-Object byte[] $chunk
        $carry = New-Object IO.MemoryStream
        $utf8 = [Text.Encoding]::UTF8
        while ($pos -lt $len) {
            $want = [int][Math]::Min([long]$chunk, $len - $pos)
            $read = $fs.Read($buf, 0, $want)
            if ($read -le 0) { break }
            $start = 0
            while ($start -lt $read) {
                $nl = [Array]::IndexOf($buf, [byte]10, $start, $read - $start)
                if ($nl -lt 0) { break }
                if ($carry.Length -gt 0) {
                    $carry.Write($buf, $start, $nl - $start)
                    $line = $utf8.GetString($carry.GetBuffer(), 0, [int]$carry.Length)
                    $carry.SetLength(0)
                } else {
                    $line = $utf8.GetString($buf, $start, $nl - $start)
                }
                Add-CNLine $State $line
                $start = $nl + 1
                $committed = $pos + $start
            }
            if ($start -lt $read -and $carry.Length -lt 64MB) { $carry.Write($buf, $start, $read - $start) }
            $pos += $read
        }
        $info.offset = $committed   # 只提交到最后一个完整行，正在写入的半行下次再读
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Update-CNLocal($State) {
    Initialize-CNScanState $State
    $proj = Join-Path (Get-CNClaudeDir) 'projects'
    if (-not (Test-Path -LiteralPath $proj)) { return $false }
    $cutoff = [DateTime]::UtcNow.AddDays(-8)
    foreach ($f in [IO.Directory]::EnumerateFiles($proj, '*.jsonl', [IO.SearchOption]::AllDirectories)) {
        try {
            $fi = New-Object IO.FileInfo($f)
            if ($fi.LastWriteTimeUtc -lt $cutoff) { continue }
            Read-CNJsonlFile $State $f $fi.Length
        } catch { }
    }
    # 清理 8 天前的记录
    $old = (Get-CNNow) - 8 * 86400
    if ($State.entries.Count -gt 0) {
        $removed = $State.entries.RemoveAll([Predicate[object]] { param($e) $e.t -lt $old })
        if ($removed -gt 0) {
            $State.seen.Clear()
            foreach ($e in $State.entries) { [void]$State.seen.Add($e.key) }
        }
    }
    return $true
}

function Get-CNLocalStats($State) {
    $now = Get-CNNow
    $todayStart = ([DateTimeOffset](Get-Date).Date).ToUnixTimeSeconds()
    $weekStart = $now - 7 * 86400
    $r = @{
        hasData = ($State.entries.Count -gt 0)
        blockActive = $false; blockStart = $null; blockEnd = $null; blockTokens = 0L; blockReq = 0; blockOut = 0L
        weekTokens = 0L; weekReq = 0; weekOut = 0L; todayTokens = 0L; todayReq = 0
        weekByFam = @{}; lastActivity = $null
    }
    if (-not $r.hasData) { return $r }
    $sorted = $State.entries | Sort-Object t
    $blk = $null
    foreach ($e in $sorted) {
        # 与常见 5 小时时段估算法一致：从首条消息所在整点开始，满 5 小时或空闲 5 小时开启新时段
        if ($null -eq $blk -or $e.t -ge $blk.end -or ($e.t - $blk.last) -ge 18000) {
            $st = $e.t - ($e.t % 3600)
            $blk = @{ start = $st; end = $st + 18000; last = $e.t; tok = 0L; req = 0; out = 0L }
        }
        $blk.last = $e.t; $blk.tok += $e.tot; $blk.req += 1; $blk.out += $e.out
        if ($e.t -ge $weekStart) {
            $r.weekTokens += $e.tot; $r.weekReq += 1; $r.weekOut += $e.out
            if (-not $r.weekByFam.ContainsKey($e.fam)) { $r.weekByFam[$e.fam] = 0L }
            $r.weekByFam[$e.fam] += $e.tot
        }
        if ($e.t -ge $todayStart) { $r.todayTokens += $e.tot; $r.todayReq += 1 }
        $r.lastActivity = $e.t
    }
    if ($blk -and $now -lt $blk.end) {
        $r.blockActive = $true; $r.blockStart = $blk.start; $r.blockEnd = $blk.end
        $r.blockTokens = $blk.tok; $r.blockReq = $blk.req; $r.blockOut = $blk.out
    }
    return $r
}

# ---------------------------------------------------------------- 状态栏桥接

function Read-CNBridge([string]$DataDir) {
    $p = Join-Path $DataDir 'bridge.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $j = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $j) { return $null }
    $wins = @()
    foreach ($k in @('five_hour', 'seven_day', 'spend_limit')) {
        $w = $null
        if ($j.rate_limits) { $w = $j.rate_limits.$k }
        if ($w -and $null -ne $w.used_percentage) {
            $item = @{ key = $k; used = [double]$w.used_percentage; resets = (ConvertTo-CNEpoch $w.resets_at) }
            if ($k -eq 'spend_limit') { $item.usedUsd = $w.used_usd; $item.limitUsd = $w.limit_usd }
            $wins += $item
        }
    }
    return @{ captured = [long]$j.captured_at; windows = $wins; model = [string]$j.model; mtime = (Get-Item -LiteralPath $p).LastWriteTimeUtc }
}

# ---------------------------------------------------------------- 官方用量接口（只读）

function Get-CNApiUsage([string]$ClaudeDir) {
    $credPath = Join-Path $ClaudeDir '.credentials.json'
    if (-not (Test-Path -LiteralPath $credPath)) { return @{ ok = $false; reason = 'nocred' } }
    $c = [IO.File]::ReadAllText($credPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $o = $c.claudeAiOauth
    if (-not $o -or -not $o.accessToken) { return @{ ok = $false; reason = 'nocred' } }
    $plan = [string]$o.subscriptionType
    $exp = ConvertTo-CNEpoch $o.expiresAt
    if ($exp -and $exp -lt (Get-CNNow)) { return @{ ok = $false; reason = 'expired'; plan = $plan } }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'Authorization' = 'Bearer ' + $o.accessToken; 'anthropic-beta' = 'oauth-2025-04-20' }
    try {
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Method Get -Headers $headers -UserAgent 'claude-niang/1.0' -TimeoutSec 15
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        return @{ ok = $false; reason = 'http'; code = $code; plan = $plan }
    }
    $wins = @()
    foreach ($k in @('five_hour', 'seven_day', 'seven_day_opus', 'seven_day_sonnet', 'seven_day_oauth_apps')) {
        $w = $r.$k
        if ($w -and $null -ne $w.utilization) {
            $wins += @{ key = $k; used = [double]$w.utilization; resets = (ConvertTo-CNEpoch $w.resets_at) }
        }
    }
    $x = $r.extra_usage
    if ($x -and $x.is_enabled -and $null -ne $x.utilization) {
        $wins += @{ key = 'extra'; used = [double]$x.utilization; resets = $null; usedCredits = $x.used_credits; limit = $x.monthly_limit }
    }
    return @{ ok = $true; windows = $wins; plan = $plan }
}

# ---------------------------------------------------------------- claude.ai 账号（桌面 App / 网页版共用的额度）
# 用户自己粘贴的 sessionKey，用 Windows DPAPI（当前用户）加密保存在 session.dat，只发送给 claude.ai。

function Protect-CNSecret([string]$Plain) {
    $ss = ConvertTo-SecureString $Plain -AsPlainText -Force
    return (ConvertFrom-SecureString $ss)
}

function Unprotect-CNSecret([string]$Enc) {
    try {
        $ss = ConvertTo-SecureString $Enc
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    } catch { return $null }
}

function Test-CNWebConnected([string]$DataDir) { return (Test-Path -LiteralPath (Join-Path $DataDir 'session.dat')) }

function Get-CNUsageWindows($r) {
    $wins = @()
    foreach ($k in @('five_hour', 'seven_day', 'seven_day_opus', 'seven_day_sonnet', 'seven_day_oauth_apps')) {
        $w = $r.$k
        if ($w -and $null -ne $w.utilization) {
            $wins += @{ key = $k; used = [double]$w.utilization; resets = (ConvertTo-CNEpoch $w.resets_at) }
        }
    }
    $x = $r.extra_usage
    if ($x -and $x.is_enabled -and $null -ne $x.utilization) {
        $wins += @{ key = 'extra'; used = [double]$x.utilization; resets = $null; usedCredits = $x.used_credits; limit = $x.monthly_limit }
    }
    return , $wins
}

function Get-CNPlanFromCaps($org) {
    $caps = @()
    try { $caps = @($org.capabilities | ForEach-Object { [string]$_ }) } catch { }
    $tier = ''
    try { $tier = [string]$org.rate_limit_tier } catch { }
    $all = (($caps -join ' ') + ' ' + $tier).ToLowerInvariant()
    if ($all -match 'max') { return 'max' }
    if ($all -match 'enterprise') { return 'enterprise' }
    if ($all -match 'raven|team') { return 'team' }
    if ($all -match 'pro') { return 'pro' }
    return ''
}

# 返回 @{ ok; reason(nokey/badkey/http/error); code; cf; windows; plan }
function Invoke-CNWebUsage([string]$Key, $State) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'Cookie' = 'sessionKey=' + $Key; 'Accept' = 'application/json' }
    $ua = 'ClaudeNiang/1.0 (Windows desktop widget)'
    $org = $null
    if ($State -and $State.webOrg) { $org = $State.webOrg }
    try {
        if (-not $org) {
            $orgs = @(Invoke-RestMethod -Uri 'https://claude.ai/api/organizations' -Method Get -Headers $headers -UserAgent $ua -TimeoutSec 15)
            $list = @($orgs | ForEach-Object { $_ } | Where-Object { $_ -and $_.uuid })
            if ($list.Count -eq 0) { return @{ ok = $false; reason = 'noorg' } }
            $chat = @($list | Where-Object { @($_.capabilities) -contains 'chat' })
            if ($chat.Count -gt 0) { $list = $chat }
            $paid = @($list | Where-Object { (Get-CNPlanFromCaps $_) -ne '' })
            if ($paid.Count -gt 0) { $list = $paid }
            $o = $list[0]
            $org = @{ uuid = [string]$o.uuid; plan = (Get-CNPlanFromCaps $o) }
            if ($State) { $State.webOrg = $org }
        }
        $r = Invoke-RestMethod -Uri ('https://claude.ai/api/organizations/{0}/usage' -f $org.uuid) -Method Get -Headers $headers -UserAgent $ua -TimeoutSec 15
    } catch {
        $code = $null; $cf = $false
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $code = [int]$resp.StatusCode
                if ($resp.Headers['cf-mitigated']) { $cf = $true }
            }
        } catch { }
        if ($State -and $code -in @(403, 404)) { $State.webOrg = $null }   # 组织可能变了，下次重新获取
        if ($code) { return @{ ok = $false; reason = 'http'; code = $code; cf = $cf } }
        return @{ ok = $false; reason = 'error' }
    }
    return @{ ok = $true; windows = (Get-CNUsageWindows $r); plan = $org.plan }
}

function Get-CNWebUsage([string]$DataDir, $State) {
    $p = Join-Path $DataDir 'session.dat'
    if (-not (Test-Path -LiteralPath $p)) { return @{ ok = $false; reason = 'nokey' } }
    $key = Unprotect-CNSecret ([IO.File]::ReadAllText($p).Trim())
    if (-not $key) { return @{ ok = $false; reason = 'badkey' } }
    return (Invoke-CNWebUsage $key $State)
}

# ---------------------------------------------------------------- 入口

function Get-CNUsage {
    param($State, $Opts)
    $res = @{ at = (Get-CNNow); local = $null; localError = $null; bridge = $null; api = $null; web = $null }
    try {
        if (Update-CNLocal $State) { $res.local = Get-CNLocalStats $State }
    } catch { $res.localError = $_.Exception.Message }
    try { $res.bridge = Read-CNBridge $Opts.dataDir } catch { }
    if ($Opts.queryWeb) {
        try { $res.web = Get-CNWebUsage $Opts.dataDir $State }
        catch { $res.web = @{ ok = $false; reason = 'error' } }
    }
    if ($Opts.queryApi) {
        try { $res.api = Get-CNApiUsage $Opts.claudeDir }
        catch { $res.api = @{ ok = $false; reason = 'error' } }
    }
    return $res
}
