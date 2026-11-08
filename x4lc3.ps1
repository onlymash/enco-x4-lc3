# x4lc3.ps1 — 管理一加 16 上 Enco X4 的双模 LC3 白名单与“常驻游戏态” (Windows PowerShell)
# 原理与验证见 BLUETOOTH.md（方案 B / C）。需要 root（su）。
$ErrorActionPreference = 'Stop'

$CONF = "/data/misc/bluedroid/bt_oplus_iot_list.conf"
$SECTION = "dualmode_a2dp_lowlatency"
$KEY = "add_list"

function Find-Adb {
    if ($env:ADB) {
        if (Test-Path -LiteralPath $env:ADB) { return $env:ADB }
        $cmd = Get-Command $env:ADB -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        Write-Host "指定的 ADB 不可执行: $env:ADB" -ForegroundColor Red
        exit 1
    }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $sdkDirs = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk")
    foreach ($d in $sdkDirs) {
        if ($d) {
            $p = Join-Path $d "platform-tools\adb.exe"
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    Write-Host "未找到 adb：请安装 Android platform-tools 并加入 PATH，或设置 `$env:ADB='C:\path\to\adb.exe'" -ForegroundColor Red
    exit 1
}

$ADB = Find-Adb

function Show-Usage {
    Write-Host @"
用法: .\x4lc3.ps1 <命令> [参数]

白名单（写入 $CONF，改动后需重启蓝牙才生效）:
  list                  显示自定义白名单与当前状态
  add <包名>...         添加应用（多个包名用空格分隔）并重启蓝牙
  del <包名>...         删除应用（多个包名用空格分隔）并重启蓝牙
  clear                 清空自定义白名单并重启蓝牙
  restart               仅重启蓝牙

常驻游戏态（让所有声音走 LC3，包名须在白名单且已安装）:
  on [包名]             开启；省略包名时使用白名单第一项
  off                   关闭，切回 LHDC/A2DP
  status                显示游戏态与当前活动设备

选项: 环境变量 `$env:NO_RESTART='1'` 可让 add/del/clear 不自动重启蓝牙。
      环境变量 `$env:ADB='C:\path\to\adb.exe'` 指定 adb（默认从 PATH 查找）。
"@
}

function Invoke-AdbShell([string]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $ADB shell $Command 2>$null
        if ($null -eq $out) { return "" }
        return ($out -join "`n").Replace("`r", "").TrimEnd("`n")
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-RootShell([string]$Command) {
    return Invoke-AdbShell "su -c '$Command'"
}

function Test-Device {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $ADB get-state 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "未检测到 adb 设备" -ForegroundColor Red
            exit 1
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-HasRoot {
    return ((Invoke-RootShell "id -u").Trim() -eq "0")
}

function Assert-Root {
    if (-not (Test-HasRoot)) {
        Write-Host "无法获取 root" -ForegroundColor Red
        exit 1
    }
}

# 默认系统不存在 $CONF，若不存在则先创建并设置权限与 SELinux 上下文
function Initialize-Conf {
    $cmd = "if [ ! -f $CONF ]; then printf '[%s]\n' '$SECTION' > $CONF && chown bluetooth:bluetooth $CONF && chmod 660 $CONF && (restorecon $CONF >/dev/null 2>&1 || true); fi"
    $null = Invoke-RootShell $cmd
}

function Get-Whitelist {
    $content = Invoke-RootShell "if [ -f $CONF ]; then cat $CONF; fi"
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }
    $inSec = $false
    $list = @()
    foreach ($line in ($content -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("[")) {
            $inSec = ($trimmed -eq "[$SECTION]")
            continue
        }
        if ($inSec -and $trimmed.Contains("=")) {
            $parts = $trimmed -split "=", 2
            if ($parts[0].Trim() -eq $KEY) {
                $items = $parts[1].Trim() -split ","
                foreach ($item in $items) {
                    $v = $item.Trim()
                    if ($v -ne "") { $list += $v }
                }
            }
        }
    }
    return $list
}

function Set-Whitelist([string[]]$Packages) {
    Initialize-Conf
    $valid = @($Packages | Where-Object { $_ -and $_.Trim() -ne "" })
    if ($valid.Count -eq 0) {
        $cmd = "cat > $CONF <<EOF`n[$SECTION]`nEOF`nchown bluetooth:bluetooth $CONF && chmod 660 $CONF && (restorecon $CONF >/dev/null 2>&1 || true)"
        $null = Invoke-RootShell $cmd
        Write-Host "白名单已清空"
        return
    }
    $joined = $valid -join ","
    $cmd = "cat > $CONF <<EOF`n[$SECTION]`n$KEY=$joined`nEOF`nchown bluetooth:bluetooth $CONF && chmod 660 $CONF && (restorecon $CONF >/dev/null 2>&1 || true)"
    $null = Invoke-RootShell $cmd
    Write-Host "白名单: $joined"
}

function Restart-Bt {
    Write-Host "重启蓝牙…"
    $null = Invoke-RootShell "svc bluetooth disable"
    Start-Sleep -Seconds 4
    $null = Invoke-RootShell "svc bluetooth enable"
    Start-Sleep -Seconds 10
    Write-Host "完成（耳机重连后生效）"
}

function Invoke-MaybeRestart {
    if ($env:NO_RESTART -eq "1") {
        Write-Host "已跳过重启，改动需重启蓝牙后生效"
    } else {
        Restart-Bt
    }
}

function Test-PackageInstalled([string]$Pkg) {
    $out = Invoke-AdbShell "pm list packages $Pkg"
    $lines = $out -split "`n" | ForEach-Object { $_.Trim() }
    return ($lines -contains "package:$Pkg")
}

function Show-Status {
    $val = Invoke-AdbShell "settings get global debug_gamemode_value"
    $pkg = Invoke-AdbShell "settings get global debug_gamemode_savegame"
    $pref = Invoke-AdbShell "settings get global oplus_games_low_latency_state"
    $coex = Invoke-AdbShell "getprop persist.sys.bt.leacoexist"
    Write-Host "游戏态: value=$val, package=$pkg, user_prefer=$pref"
    Write-Host "共存开关 persist.sys.bt.leacoexist=$coex"
    Write-Host "最近的活动设备切换:"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $dump = & $ADB shell "dumpsys bluetooth_manager" 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($dump) {
        $matches = $dump | Select-String -Pattern "Active Device Changed" | Select-Object -Last 4
        foreach ($m in $matches) {
            Write-Host ("  " + $m.Line.Trim())
        }
    }
}

function Show-List {
    Assert-Root
    Write-Host "自定义白名单 ($CONF):"
    $list = Get-Whitelist
    foreach ($item in $list) {
        Write-Host "  $item"
    }
    Write-Host "（系统内置白名单见 BLUETOOTH.md 第 3.2 节）"
    Write-Host ""
    Show-Status
}

function Add-Packages([string[]]$NewPkgs) {
    if (-not $NewPkgs -or $NewPkgs.Count -eq 0) { Show-Usage; exit 1 }
    Assert-Root
    Initialize-Conf
    $cur = [System.Collections.Generic.List[string]]::new()
    foreach ($i in (Get-Whitelist)) { $cur.Add($i) }
    foreach ($p in $NewPkgs) {
        if (-not (Test-PackageInstalled $p)) {
            Write-Host "警告: $p 未安装（白名单仍会写入）" -ForegroundColor Yellow
        }
        if (-not $cur.Contains($p)) {
            $cur.Add($p)
        }
    }
    Set-Whitelist $cur.ToArray()
    Invoke-MaybeRestart
}

function Remove-Packages([string[]]$DelPkgs) {
    if (-not $DelPkgs -or $DelPkgs.Count -eq 0) { Show-Usage; exit 1 }
    Assert-Root
    Initialize-Conf
    $cur = Get-Whitelist | Where-Object { $DelPkgs -notcontains $_ }
    Set-Whitelist @($cur)
    Invoke-MaybeRestart
}

function Enable-GameMode([string]$Pkg) {
    if ([string]::IsNullOrWhiteSpace($Pkg)) {
        Assert-Root
        $list = Get-Whitelist
        if ($list.Count -gt 0) { $Pkg = $list[0] }
        if ([string]::IsNullOrWhiteSpace($Pkg)) {
            Write-Host "白名单为空，请先 add 或指定包名" -ForegroundColor Red
            exit 1
        }
    } elseif (Test-HasRoot) {
        $list = Get-Whitelist
        if ($list -notcontains $Pkg) {
            Write-Host "警告: $Pkg 不在自定义白名单，若不在系统内置名单中将不会生效" -ForegroundColor Yellow
        }
    }
    if (-not (Test-PackageInstalled $Pkg)) {
        Write-Host "警告: $Pkg 未安装，需至少安装一个白名单应用才会启用双连接" -ForegroundColor Yellow
    }
    $null = Invoke-AdbShell "settings put global debug_gamemode_savegame $Pkg"
    $prop = Invoke-AdbShell "getprop ro.oplus.audio.support.low_latency_game"
    if ($prop -eq "true") {
        $null = Invoke-AdbShell "settings put global oplus_games_low_latency_state ${Pkg}:1"
    }
    $null = Invoke-AdbShell "settings put global debug_gamemode_value 1"
    Write-Host "已开启常驻游戏态: $Pkg"
}

function Disable-GameMode {
    $null = Invoke-AdbShell "settings put global debug_gamemode_value 0"
    Write-Host "已关闭常驻游戏态"
}

if ($args.Count -lt 1) { Show-Usage; exit 1 }
$cmd = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }

if ($cmd -in @("-h", "--help", "help")) { Show-Usage; exit 0 }

Test-Device

switch ($cmd) {
    "list"    { Show-List }
    "add"     { Add-Packages $rest }
    { $_ -in @("del", "rm", "remove") } { Remove-Packages $rest }
    "clear"   { Assert-Root; Set-Whitelist @(); Invoke-MaybeRestart }
    "restart" { Assert-Root; Restart-Bt }
    "on"      { Enable-GameMode ($rest | Select-Object -First 1) }
    "off"     { Disable-GameMode }
    "status"  { Show-Status }
    default   { Show-Usage; exit 1 }
}
