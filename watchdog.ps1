<#
.SYNOPSIS
    Quest VD Wired watchdog - USB リンクが落ちたら自動で復旧させる常駐スクリプト。

.DESCRIPTION
    リンクが生きているかを次の 3 条件で判定し、欠けた状態が続いたら
    quest-vd-wired を起動し直す。

      1. Quest 側に tun インターフェースがある
      2. PC 側で quest-vd-wired.exe が動いている
      3. adb reverse のマッピングが張られている

    HMD の電源 OFF -> ON、スリープ復帰、ケーブル抜き差し、そして
    PC 側の再起動からの復帰を自動化する。

    設定は初回実行時に watchdog.config.json として自動生成される。
    パスが自動検出できなかった場合はそのファイルを編集すること。

.PARAMETER Install
    Windows スタートアップに登録し、ログオン時に自動起動するようにする。

.PARAMETER Uninstall
    スタートアップ登録を解除する。

.PARAMETER Show
    自動起動時にウィンドウを表示する (-Install と併用)。既定は非表示。

.EXAMPLE
    .\watchdog.ps1 -Install
    常駐を開始し、以後のログオン時にも自動起動するようにする。install.cmd の中身。

.EXAMPLE
    .\watchdog.ps1
    前景で実行する。自動起動の登録はしない。run_debug.cmd の中身。

.EXAMPLE
    .\watchdog.ps1 -Uninstall
    常駐を停止し、自動起動の登録も解除する。uninstall.cmd の中身。

.NOTES
    やってはいけないこと (実測で確認済み):
      * quest-vd-wired.exe をサブコマンド付きで叩く
        -> 常駐中のセッションを巻き込んで落とす。status / repair / start / stop すべて不可。
      * adb kill-server
        -> adb reverse のマッピングが消え、リンクが壊れる。
      * ping による疎通確認
        -> gnirehtet は ICMP を中継しないため、正常時でも 100% ロスになる。

    このスクリプトは Quest VD Wired を外部から起動するだけで、
    その配布物やソースを一切含まない。
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Show
)

$ErrorActionPreference = "Stop"

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path -Parent $ScriptPath
$ConfigPath = Join-Path $ScriptDir "watchdog.config.json"
$TaskName   = "quest-vd-wired-watchdog"

# ---- 既定値 --------------------------------------------------------------
$Defaults = [ordered]@{
    adbPath           = ""    # 空なら自動検出
    questVdWiredPath  = ""    # 空なら自動検出
    logPath           = ""    # 空なら %LOCALAPPDATA%\GnirehtetVD\watchdog.log
    intervalSec       = 10    # 監視間隔
    failThreshold     = 3     # 連続何回異常を見たら再起動するか
    settleSec         = 60    # 再起動後、復帰を待つ上限
    settlePollSec     = 2     # 復帰待ち中の確認間隔
    cmdTimeoutSec     = 10    # adb コマンドが固まったときの打ち切り
    maxRestarts       = 3     # 連続何回まで再起動を試みるか
    giveUpWaitSec     = 600   # 上限に達したあと、次に再起動を試みるまでの待ち時間
}

# Quest 側クライアントのパッケージ名。Quest VD Wired が導入するもの。
$AndroidPackage = "com.genymobile.gnirehtet"

# ---- パス自動検出 --------------------------------------------------------

function Find-Adb {
    $candidates = @()

    # Quest VD Wired 同梱のもの (バージョン番号が変わっても拾えるようにワイルドカード)
    $home_ = Join-Path $env:LOCALAPPDATA "GnirehtetVD"
    if (Test-Path $home_) {
        $candidates += Get-ChildItem $home_ -Recurse -Filter "adb.exe" -ErrorAction SilentlyContinue |
                       ForEach-Object { $_.FullName }
    }

    # PATH 上のもの
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    # Android SDK の既定位置
    $sdk = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
    if (Test-Path $sdk) { $candidates += $sdk }

    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return ""
}

function Find-QuestVdWired {
    # スクリプトと同じフォルダ、次に親フォルダ (watchdog/ の中に置かれた場合)
    $local = Join-Path $ScriptDir "quest-vd-wired.exe"
    if (Test-Path $local) { return $local }

    $parent = Split-Path -Parent $ScriptDir
    if ($parent) {
        $up = Join-Path $parent "quest-vd-wired.exe"
        if (Test-Path $up) { return $up }
    }

    # 実行中のプロセスから逆引き。
    # パス全体ではなく実行ファイル名で判定する (フォルダ名に quest-vd-wired を
    # 含む場所に置かれた無関係な exe を拾わないため)。
    $proc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "quest-vd-wired.exe" } |
            Select-Object -First 1
    if ($proc -and $proc.ExecutablePath) { return $proc.ExecutablePath }

    return ""
}

# ---- 設定の読み書き ------------------------------------------------------

function Read-Config {
    $cfg = [ordered]@{}
    foreach ($key in $Defaults.Keys) { $cfg[$key] = $Defaults[$key] }

    if (Test-Path $ConfigPath) {
        $json = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($cfg.Keys)) {
            if ($null -ne $json.$key -and "$($json.$key)" -ne "") { $cfg[$key] = $json.$key }
        }
    }

    # 自動検出するのは値が空のときだけ。
    # 利用者が書いた値は、たとえ現時点で存在しなくても勝手に書き換えない
    # (タイプミスや、一時的に外れているドライブを黙って消してしまわないため)。
    $created = $false
    if ("$($cfg.adbPath)" -eq "") {
        $cfg.adbPath = Find-Adb; $created = $true
    } elseif (-not (Test-Path $cfg.adbPath)) {
        Write-Host "設定された adbPath が見つかりません: $($cfg.adbPath)" -ForegroundColor Yellow
    }

    if ("$($cfg.questVdWiredPath)" -eq "") {
        $cfg.questVdWiredPath = Find-QuestVdWired; $created = $true
    } elseif (-not (Test-Path $cfg.questVdWiredPath)) {
        Write-Host "設定された questVdWiredPath が見つかりません: $($cfg.questVdWiredPath)" -ForegroundColor Yellow
    }
    if ("$($cfg.logPath)" -eq "") {
        $cfg.logPath = Join-Path $env:LOCALAPPDATA "GnirehtetVD\watchdog.log"
    }

    if ($created -or -not (Test-Path $ConfigPath)) { Write-Config $cfg }
    return $cfg
}

function Write-Config($cfg) {
    $json = [pscustomobject]$cfg | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($true)))
}

# ---- インストール / アンインストール --------------------------------------

function Get-ShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) "$TaskName.lnk"
}

# 常駐中かどうかはミューテックスの有無で判定する。
# コマンドライン文字列で探すと無関係なプロセスまで拾ってしまう。
$MutexName = "Local\quest-vd-wired-watchdog"

function Test-AlreadyRunning {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting($MutexName, [ref]$m)) {
        $m.Dispose()
        return $true
    }
    return $false
}

# 停止対象は「-File でこのスクリプト自身を実行しているループ本体」だけに絞る。
# ファイル名だけで探すと、同名の別スクリプトを巻き添えにする。
function Get-WatchdogProcesses {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -like "*-File*" -and
            $_.CommandLine -like "*$ScriptPath*" -and
            $_.CommandLine -notlike "*-Install*" -and
            $_.CommandLine -notlike "*-Uninstall*" -and
            $_.CommandLine -notlike "*-Command*"
        }
}

function Install-Startup {
    # 設定ファイルをこの時点で生成し、検出結果を見せる。
    # 「登録はできたがパスが合っているか分からない」状態を避けるため。
    $cfg = Read-Config
    Write-Host "config : $ConfigPath"
    if ("$($cfg.adbPath)" -ne "" -and (Test-Path $cfg.adbPath)) {
        Write-Host "  adb  : $($cfg.adbPath)"
    } else {
        Write-Host "  adb  : NOT FOUND - watchdog.config.json の adbPath を設定してください" -ForegroundColor Red
    }
    if ("$($cfg.questVdWiredPath)" -ne "" -and (Test-Path $cfg.questVdWiredPath)) {
        Write-Host "  app  : $($cfg.questVdWiredPath)"
    } else {
        Write-Host "  app  : NOT FOUND - watchdog.config.json の questVdWiredPath を設定してください" -ForegroundColor Red
    }
    Write-Host ""

    $lnk = Get-ShortcutPath
    $style = "-WindowStyle Hidden"
    $wstyle = 7
    if ($Show) { $style = ""; $wstyle = 1 }

    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    # -NoProfile は必須。利用者のプロファイルが自動起動のたびに実行されると、
    # ウィンドウ非表示のまま止まったり失敗したりして気づけない。
    $sc.Arguments  = ("{0} -NoProfile -ExecutionPolicy Bypass -File `"{1}`"" -f $style, $ScriptPath).Trim()
    $sc.WorkingDirectory = $ScriptDir
    $sc.WindowStyle = $wstyle
    $sc.Description = "Quest VD Wired watchdog"
    $sc.Save()

    Write-Host "スタートアップに登録しました。次回ログオン時から自動で起動します。"
    Write-Host "  $lnk"
    Write-Host ""

    # 登録しただけでは今回は動かないので、その場で常駐も開始する。
    if (Test-AlreadyRunning) {
        Write-Host "既に常駐しています。"
    } else {
        $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ScriptPath`"")
        if ($Show) { Start-Process powershell -ArgumentList $psArgs | Out-Null }
        else       { Start-Process powershell -ArgumentList $psArgs -WindowStyle Hidden | Out-Null }
        Start-Sleep -Seconds 4
        if (Test-AlreadyRunning) {
            $p = @(Get-WatchdogProcesses)
            if ($p.Count -gt 0) { Write-Host "常駐を開始しました (pid $($p[0].ProcessId))。" }
            else                { Write-Host "常駐を開始しました。" }
            Write-Host "タスクトレイのアイコンで状態を確認できます (緑=接続中 / 灰=未接続 / 赤=復旧中)。"
        } else {
            Write-Host "常駐の開始に失敗しました。run_debug.cmd で前景実行してエラーを確認してください。" -ForegroundColor Red
        }
    }
    Write-Host ""
    Write-Host "ログ: $((Read-Config).logPath)"
}

function Uninstall-Startup {
    $lnk = Get-ShortcutPath
    if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "uninstalled: $lnk" }
    else { Write-Host "not installed" }

    $stopped = 0
    Get-WatchdogProcesses | ForEach-Object {
        Write-Host "stopping running instance $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $stopped++
    }
    if ($stopped -eq 0) { Write-Host "常駐しているインスタンスはありません。" }
}

if ($Install)   { Install-Startup;   return }
if ($Uninstall) { Uninstall-Startup; return }

# ---- 起動時チェック ------------------------------------------------------

$cfg = Read-Config

if ("$($cfg.adbPath)" -eq "" -or -not (Test-Path $cfg.adbPath)) {
    Write-Host "adb.exe が見つかりません。$ConfigPath の adbPath を設定してください。" -ForegroundColor Red
    return
}
if ("$($cfg.questVdWiredPath)" -eq "" -or -not (Test-Path $cfg.questVdWiredPath)) {
    Write-Host "quest-vd-wired.exe が見つかりません。$ConfigPath の questVdWiredPath を設定してください。" -ForegroundColor Red
    return
}

# 多重起動の防止。以前これで再起動が競合し、入力が奪われる不具合が起きた。
# 前回のインスタンスが強制終了されているとミューテックスが放棄状態になるが、
# それは「誰も掴んでいない」ということなので取得成功として扱う。
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$acquired = $false
try {
    $acquired = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
}
if (-not $acquired) {
    Write-Host "既に別のインスタンスが動作しています。終了します。" -ForegroundColor Yellow
    return
}

# 数値は下限を設けて取り込む。
# 0 や非数値をそのまま使うと待ち時間が消えてループが暴走したり、
# 型変換の例外で (非表示起動だと誰にも見えないまま) 起動に失敗する。
function Get-IntSetting($Value, [int]$Default, [int]$Min) {
    $n = $Default
    try { $n = [int]$Value } catch { $n = $Default }
    if ($n -lt $Min) { $n = $Min }
    return $n
}

$Adb           = [string]$cfg.adbPath
$Vd            = [string]$cfg.questVdWiredPath
$LogFile       = [string]$cfg.logPath
$IntervalSec   = Get-IntSetting $cfg.intervalSec    10  2
$FailThreshold = Get-IntSetting $cfg.failThreshold   3  1
$SettleSec     = Get-IntSetting $cfg.settleSec      60  5
$SettlePollSec = Get-IntSetting $cfg.settlePollSec   2  1
$CmdTimeoutSec = Get-IntSetting $cfg.cmdTimeoutSec  10  2
$MaxRestarts   = Get-IntSetting $cfg.maxRestarts     3  1
$GiveUpWaitSec = Get-IntSetting $cfg.giveUpWaitSec 600 30

$logDir = Split-Path -Parent $LogFile
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# ---- ユーティリティ ------------------------------------------------------

function Write-Log([string]$Message) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding utf8 } catch { }
}

# ---- タスクトレイ --------------------------------------------------------
# 常駐していることが目で分かるようにアイコンを出す。
#   緑   = リンク健全
#   灰   = デバイス未接続 (ケーブル / 電源 OFF)
#   赤   = 異常検知中・復旧作業中

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-DotIcon([System.Drawing.Color]$Color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 0, 0, 0)), 1
    $g.DrawEllipse($pen, 2, 2, 12, 12)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

$IconOk   = New-DotIcon ([System.Drawing.Color]::FromArgb(60, 190, 90))
$IconIdle = New-DotIcon ([System.Drawing.Color]::FromArgb(150, 150, 150))
$IconBad  = New-DotIcon ([System.Drawing.Color]::FromArgb(220, 70, 70))

$script:ForceRestart = $false
$script:Quit         = $false

$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon    = $IconIdle
$Tray.Text    = "Quest VD Wired watchdog"
$Tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miState = $menu.Items.Add("起動中...")
$miState.Enabled = $false
$menu.Items.Add("-") | Out-Null

$miLog = $menu.Items.Add("ログを開く")
$miLog.add_Click({ try { Start-Process notepad.exe $LogFile } catch { } })

$miCfg = $menu.Items.Add("設定ファイルを開く")
$miCfg.add_Click({ try { Start-Process notepad.exe $ConfigPath } catch { } })

$miNow = $menu.Items.Add("今すぐ再接続")
$miNow.add_Click({ $script:ForceRestart = $true })

$menu.Items.Add("-") | Out-Null

$miExit = $menu.Items.Add("終了")
$miExit.add_Click({ $script:Quit = $true })

$Tray.ContextMenuStrip = $menu

function Set-Tray([string]$State, [string]$Detail) {
    switch ($State) {
        "ok"     { $Tray.Icon = $IconOk }
        "idle"   { $Tray.Icon = $IconIdle }
        default  { $Tray.Icon = $IconBad }
    }
    # ツールチップは 63 文字までしか表示されない
    $text = "Quest VD Wired watchdog`n$Detail"
    if ($text.Length -gt 62) { $text = $text.Substring(0, 62) }
    $Tray.Text = $text
    $miState.Text = $Detail
}

# Start-Sleep の代わり。待っている間もトレイ操作に反応させる。
#
# -IgnoreForce は復旧待ちの最中に使う。既に再起動処理中なので「今すぐ再接続」で
# 抜けても意味がなく、フラグが立ったまま即座に返り続けると adb を連続起動する
# 暴走になる。復旧待ち中はフラグを捨てる。
function Wait-Tick([int]$Seconds, [switch]$IgnoreForce) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:Quit) { return }
        if ($script:ForceRestart) {
            if ($IgnoreForce) { $script:ForceRestart = $false }
            else { return }
        }
        Start-Sleep -Milliseconds 150
    }
}

# 一時ファイルは専用フォルダに置く。
# adb は初回呼び出しで常駐サーバーを fork するが、そのサーバーが
# リダイレクト先のハンドルを継承するため、削除に失敗して残ることがある。
# 放置すると %TEMP% を埋め尽くし、最終的に GetTempFileName() が例外を投げる。
$TempDir = Join-Path $env:TEMP "quest-vd-wired-watchdog"
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

# 起動時に前回の残骸を掃除する (使用中のものは失敗するが無視してよい)。
Get-ChildItem $TempDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-5) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$script:TempSeq = 0

function Invoke-Bounded([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec) {
    $script:TempSeq++
    $base = Join-Path $TempDir ("{0}-{1}" -f $PID, $script:TempSeq)
    $out = "$base.out"
    $err = "$base.err"
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -PassThru -NoNewWindow `
                           -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return @{ TimedOut = $true; Output = "" }
        }
        $text = (Get-Content $out -Raw -ErrorAction SilentlyContinue)
        if ($null -eq $text) { $text = "" }
        return @{ TimedOut = $false; Output = $text }
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function Test-DevicePresent {
    $r = Invoke-Bounded $Adb @("devices") $CmdTimeoutSec
    if ($r.TimedOut) { return $false }
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match "^\S+\s+device\s*$") { return $true }
    }
    return $false
}

# Quest 側に VPN インターフェースがあるか。正常時は次の行が出る:
#   29: tun0    inet 10.0.0.2/32 scope global tun0
function Test-TunPresent {
    $r = Invoke-Bounded $Adb @("shell", "ip", "-o", "addr") $CmdTimeoutSec
    if ($r.TimedOut) { return $false }
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match "\btun\d+\b" -and $line -match "\binet\b") { return $true }
    }
    return $false
}

# Quest 側のクライアントアプリが動いているか。
# HMD の電源を入れ直すと確実に消える。tun が残るケースと違い、
# ここが false なら一過性ではない確定的な異常。
function Test-AndroidAppRunning {
    $r = Invoke-Bounded $Adb @("shell", "pidof", $AndroidPackage) $CmdTimeoutSec
    if ($r.TimedOut) { return $true }   # 判定できないときは異常と決めつけない

    # adb サーバーが起動していないとき、adb は PID の前に
    #   * daemon not running; starting now at tcp:5037
    #   * daemon started successfully
    # を標準出力に混ぜてくる。PC 再起動直後がまさにこれなので、
    # 単純な先頭一致で判定すると「動いていない」と誤判定してしまう。
    foreach ($line in ($r.Output -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq "" -or $t.StartsWith("*")) { continue }
        if ($t -match "^\d+$") { return $true }
    }
    return $false
}

# PC 側のホストプロセスが動いているか。
function Test-HostRunning {
    $vdName = Split-Path -Leaf $Vd
    $p = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -eq $vdName })
    return ($p.Count -gt 0)
}

# adb reverse のマッピングが張られているか。
# マッピングは adb サーバー内に保持されるので、PC の再起動やホストプロセスの
# 消失で失われる。読み取りのみで、接続には干渉しない。
function Test-ReverseMappings {
    $r = Invoke-Bounded $Adb @("reverse", "--list") $CmdTimeoutSec
    if ($r.TimedOut) { return $false }
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match "tcp:\d+") { return $true }
    }
    return $false
}

# リンクが本当に生きているか。
#
# tun の有無だけでは不十分。HMD を起動したまま PC を再起動すると、Quest 側の
# VpnService は生き残るため tun0 は残るが、PC 側にはホストプロセスも
# adb reverse マッピングも存在しない。殻だけが残った状態を「健全」と
# 誤判定しないよう、PC 側の 2 条件も必ず確認する。
function Test-Link {
    if (-not (Test-HostRunning))     { return $false }
    if (-not (Test-ReverseMappings)) { return $false }
    return (Test-TunPresent)
}

# CLI サブコマンドは使わない。プロセスを入れ替えて GUI として起動し直すだけ。
#
# 対象は実行ファイル名で判定する。パス全体で "*quest-vd-wired*" を探すと、
# インストール先フォルダ名がそれを含む場合 (既定の quest-vd-wired-vX.Y.Z-windows-x64 が
# まさにそう) に、同じフォルダ配下の無関係な exe まで巻き添えにする。
# 特に adb.exe を落とすと adb reverse のマッピングが消えてリンクが壊れる。
function Restart-Link {
    $vdName = Split-Path -Leaf $Vd
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $vdName } |
        ForEach-Object {
            Write-Log ("stopping pid {0}" -f $_.ProcessId)
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {
                Write-Log ("  stop failed: {0}" -f $_.Exception.Message)
            }
        }
    Start-Sleep -Seconds 1
    Write-Log "starting quest-vd-wired"
    # 本来の場所から起動したときと同じ作業ディレクトリにしておく。
    # exe が消えている / ドライブが外れている場合に例外で常駐ごと死なないよう握る。
    try {
        Start-Process -FilePath $Vd -WorkingDirectory (Split-Path -Parent $Vd)
    } catch {
        Write-Log ("  start failed: {0}" -f $_.Exception.Message)
    }
}

# ---- メインループ --------------------------------------------------------

try {
    Write-Log ("watchdog started (interval={0}s threshold={1})" -f $IntervalSec, $FailThreshold)
    Write-Log ("  adb: {0}" -f $Adb)
    Write-Log ("  app: {0}" -f $Vd)

    $failures  = 0
    $restarts  = 0
    $lastState = ""

    Set-Tray "idle" "起動しました"

    while ($true) {
        if ($script:Quit) { Write-Log "terminated from tray menu"; break }

        # 1 周期のどこかで例外が出ても常駐ごと死なせない。
        # $ErrorActionPreference = "Stop" のため、adb の一時ファイル生成や
        # プロセス操作が失敗しただけでループを抜けてしまうのを防ぐ。
        try {

        if (-not (Test-DevicePresent)) {
            # ケーブル接触不良 / HMD 電源 OFF。再起動しても無駄なので待つだけ。
            if ($lastState -ne "no-device") {
                Write-Log "device not attached - waiting"
                $lastState = "no-device"
            }
            Set-Tray "idle" "未接続 - Quest を待機中"
            # 切断をまたいで再起動回数を持ち越すと、次の障害で 1 度も
            # 復旧を試みないまま待機に入ってしまう。ここで戻す。
            $failures = 0
            $restarts = 0
        }
        elseif (Test-Link) {
            if ($lastState -ne "ok") {
                Write-Log "link healthy"
                $lastState = "ok"
            }
            Set-Tray "ok" ("接続中 " + (Get-Date -Format "HH:mm:ss"))
            $failures = 0
            $restarts = 0
        }
        else {
            # どちらかのアプリがそもそも起動していない場合は待たずに再起動する。
            # しきい値は USB 接触の一瞬のフラつきを吸収するためのものだが、
            # 「アプリが動いていない」は一過性の現象ではなく確定的な異常。
            #   PC 再起動   -> PC 側のホストプロセスが消える
            #   HMD 電源 ON -> Quest 側のクライアントが消える
            # ここで待つと 20〜30 秒を無駄にする。
            if (-not (Test-HostRunning)) {
                $failures = $FailThreshold
                Write-Log "host not running - restarting immediately"
            } elseif (-not (Test-AndroidAppRunning)) {
                $failures = $FailThreshold
                Write-Log "android app not running - restarting immediately"
            } else {
                $failures++
                Write-Log ("link down ({0}/{1})" -f $failures, $FailThreshold)
            }
            Set-Tray "bad" ("切断を検知 ({0}/{1})" -f $failures, $FailThreshold)
            $lastState = "down"

            if ($failures -ge $FailThreshold) {
                if ($restarts -ge $MaxRestarts) {
                    Write-Log ("restart did not help {0} times - backing off for {1}s (manual 'Diagnose and fix' may be needed)" -f $restarts, $GiveUpWaitSec)
                    Set-Tray "bad" "復旧できず - 手動対応が必要かもしれません"
                    # ここでは「今すぐ再接続」で抜けられるようにしておく (待機の短縮になる)
                    Wait-Tick $GiveUpWaitSec
                    # 「今すぐ再接続」で待機を抜けた場合、フラグを消さずに
                    # continue すると次周期で二重に再起動が走る。ここで消費する。
                    $script:ForceRestart = $false
                    $failures = 0
                    $restarts = 0
                    $lastState = ""
                    continue
                }

                $restarts++
                Write-Log ("threshold reached - restarting ({0}/{1})" -f $restarts, $MaxRestarts)
                Set-Tray "bad" ("再接続中 ({0}/{1})" -f $restarts, $MaxRestarts)
                $t0 = Get-Date
                Restart-Link

                # 固定で待たず、復帰した時点で抜ける。
                $recovered = $false
                while (((Get-Date) - $t0).TotalSeconds -lt $SettleSec) {
                    Wait-Tick $SettlePollSec -IgnoreForce
                    if ($script:Quit) { break }
                    if (Test-Link) { $recovered = $true; break }
                }
                $elapsed = [int]((Get-Date) - $t0).TotalSeconds
                if ($recovered) {
                    Write-Log ("link healthy - recovered in {0}s" -f $elapsed)
                    $lastState = "ok"
                    $restarts = 0
                } else {
                    Write-Log ("still down after {0}s" -f $elapsed)
                    $lastState = "down"
                }
                $failures = 0
                $script:ForceRestart = $false
                continue
            }
        }

        Wait-Tick $IntervalSec

        # トレイの「今すぐ再接続」
        if ($script:ForceRestart) {
            $script:ForceRestart = $false
            Write-Log "manual restart requested from tray"
            Set-Tray "bad" "再接続中 (手動)"
            Restart-Link
            Wait-Tick 10
            $failures = 0
            $lastState = ""
        }

        } catch {
            Write-Log ("iteration error: {0}" -f $_.Exception.Message)
            $lastState = ""
            Wait-Tick $IntervalSec
        }
    }
}
finally {
    try { $Tray.Visible = $false; $Tray.Dispose() } catch { }
    try { $IconOk.Dispose(); $IconIdle.Dispose(); $IconBad.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
