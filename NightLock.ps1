<#
    NightLock - portable control panel for the nightly computer lock.
    Run with no arguments for the window, -Install for the one click setup,
    -StopNow to disarm everything from the command line.
    Keep this file saved as UTF-8 with BOM.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$StopNow,
    [switch]$NoArm,
    [switch]$CheckUI
)

$ErrorActionPreference = 'Stop'

$SourceDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:ProgramData 'GoodNight'

$TaskStart  = 'GoodNight_Start'
$TaskStop   = 'GoodNight_Stop'
$TaskPatrol = 'GoodNight_Patrol'
$TaskNotify = 'GoodNight_Notify'
$LegacyTasks = @('NightLock_Start', 'NightLock_Stop', 'NightLock_Patrol', 'NightLock_Notify',
                 'NightGuard_Lock', 'NightGuard_Unlock', 'NightGuard_Supervise', 'NightGuard_TestRestore')
$LegacyConfigs = @('C:\ProgramData\NightLock\config.json', 'C:\ProgramData\NightGuard\config.json')

# ------------------------------------------------------------- config --------

function Get-RuntimeDir {
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'guard.ps1')) { return $InstallDir }
    return $SourceDir
}

function Get-RuntimePaths {
    $dir = Get-RuntimeDir
    return [ordered]@{
        Dir    = $dir
        Config = Join-Path $dir 'config.json'
        Guard  = Join-Path $dir 'guard.ps1'
        Log    = Join-Path $dir 'logs\guard.log'
        AppLog = Join-Path $dir 'logs\app.log'
        Image  = Join-Path $dir 'night-lock.png'
    }
}

function Write-AppLog {
    param([string]$Message)
    try {
        $paths = Get-RuntimePaths
        $dir = Split-Path -Parent $paths.AppLog
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [panel] ' + $Message
        Add-Content -LiteralPath $paths.AppLog -Value $line -Encoding UTF8
        # keep the log small: at 100 lines drop the oldest 50
        $all = @(Get-Content -LiteralPath $paths.AppLog -Encoding UTF8)
        if ($all.Count -ge 100) {
            $kept = $all[($all.Count - 50)..($all.Count - 1)]
            Set-Content -LiteralPath $paths.AppLog -Value $kept -Encoding UTF8
        }
    } catch { }
}

function New-DefaultConfig {
    param([string]$BaseDir, [string]$Password)
    return [ordered]@{
        StartTime           = '23:00'
        EndTime             = '06:00'
        PatrolMinutes       = 1
        EnablePassword      = $true
        UnlockPassword      = $Password
        ImagePath           = (Join-Path $BaseDir 'night-lock.png')
        MaxLockHours        = 12
        EscHoldSeconds      = 15
        UsbUnlockFileName   = 'NIGHTGUARD-UNLOCK.txt'
        EnableKeyboardBlock = $true
        WaitUnlockMinutes   = 20
        RotatePassword      = $true
        Notify              = [ordered]@{
            Enabled       = $false
            Channel       = 'none'
            Webhook       = ''
            Secret        = ''
            MailFrom      = ''
            MailAuthCode  = ''
            MailTo        = ''
            OnLock        = $true
            BeforeMinutes = 5
        }
        Texts               = [ordered]@{
            UnlockTyping = '输入应急口令，回车确认，按 Esc 取消：'
            UnlockHold   = '继续按住 Esc，还差 {0} 秒'
            UnlockWrong  = '口令不对，请重新输入。'
            MaskChar     = '●'
            PowerOff     = '关 机'
            Reboot       = '重 启'
            WaitUnlock   = '等待解锁：还差 {0} 分钟'
            WaitReady    = '现在可以解锁了，点这里'
            MailSubject  = '【晚安】解锁口令'
            MsgOnLock    = '电脑已进入锁定状态。解锁口令：{0}，或等到 {1} 自动解除。'
            MsgBefore    = '还有 {0} 分钟开始锁定。解锁口令：{1}'
            MsgNoPassword = '电脑已进入锁定状态。本次没有启用应急口令，可用等待解锁（{0} 分钟后）或插 U 盘解锁，或等到 {1} 自动解除。'
            StatusOnLock  = '电脑已进入锁定状态'
            StatusBefore  = '还有 {0} 分钟开始锁定'
            TailOnLock    = '（到 {0} 自动解除）'
            PasswordOff   = '未启用（锁屏时靠 U 盘或等待解锁）'
            MsgFull       = "【晚安】{0}`n锁定时段：每天 {1} 到次日 {2}`n应急口令：{3}`n等待解锁：{4}`n巡查间隔：每 {5} 分钟检查一次`n{6}"
            InfoNight     = '锁屏时段：每天 {0} 到次日 {1}'
            InfoForced    = '本次锁定时长 {0}　·　剩余 {1}'
            DurationHM    = '{0} 小时 {1} 分钟'
            DurationM     = '{0} 分钟'
        }
    }
}

function New-RandomPassword {
    $alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    $chars = $bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] }
    return (-join $chars)
}

function Get-AppConfig {
    $paths = Get-RuntimePaths
    if (-not (Test-Path -LiteralPath $paths.Config)) { return $null }
    try {
        return (Get-Content -LiteralPath $paths.Config -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-AppLog ('config read failed: ' + $_.Exception.Message)
        return $null
    }
}

function Save-AppConfig {
    param($Config)
    # self heal: make sure every text template the guard needs is present
    $defaultTexts = [ordered]@{
        UnlockTyping  = '输入应急口令，回车确认，按 Esc 取消：'
        UnlockHold    = '继续按住 Esc，还差 {0} 秒'
        UnlockWrong   = '口令不对，请重新输入。'
        MaskChar      = '●'
        PowerOff      = '关 机'
        Reboot        = '重 启'
        WaitUnlock    = '等待解锁：还差 {0} 分钟'
        WaitReady     = '现在可以解锁了，点这里'
        MailSubject   = '【晚安】解锁口令'
        MsgOnLock     = '电脑已进入锁定状态。解锁口令：{0}，或等到 {1} 自动解除。'
        MsgBefore     = '还有 {0} 分钟开始锁定。解锁口令：{1}'
        MsgNoPassword = '电脑已进入锁定状态。本次没有启用应急口令，可用等待解锁（{0} 分钟后）或插 U 盘解锁，或等到 {1} 自动解除。'
        StatusOnLock  = '电脑已进入锁定状态'
        StatusBefore  = '还有 {0} 分钟开始锁定'
        TailOnLock    = '（到 {0} 自动解除）'
        PasswordOff   = '未启用（锁屏时靠 U 盘或等待解锁）'
        MsgFull       = "【晚安】{0}`n锁定时段：每天 {1} 到次日 {2}`n应急口令：{3}`n等待解锁：{4}`n巡查间隔：每 {5} 分钟检查一次`n{6}"
        InfoNight     = '锁屏时段：每天 {0} 到次日 {1}'
        InfoForced    = '本次锁定时长 {0}　·　剩余 {1}'
        DurationHM    = '{0} 小时 {1} 分钟'
        DurationM     = '{0} 分钟'
    }
    if (-not $Config.Texts) {
        $Config | Add-Member -NotePropertyName Texts -NotePropertyValue $defaultTexts -Force
    } else {
        foreach ($k in $defaultTexts.Keys) {
            $cur = $Config.Texts.PSObject.Properties[$k]
            if (-not $cur -or [string]::IsNullOrWhiteSpace([string]$cur.Value)) {
                $Config.Texts | Add-Member -NotePropertyName $k -NotePropertyValue $defaultTexts[$k] -Force
            }
        }
    }
    $paths = Get-RuntimePaths
    $dir = Split-Path -Parent $paths.Config
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($Config | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $paths.Config -Encoding UTF8
}

function Get-LockProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -like '*guard.ps1*' -and
            $_.CommandLine -like '*GoodNight*' -and $_.CommandLine -like '*-Mode lock*'
        })
}

function Test-Installed {
    return (@(Get-ScheduledTask -TaskName $TaskStart -ErrorAction SilentlyContinue).Count -gt 0)
}

function Stop-LockNow {
    $paths = Get-RuntimePaths
    if (Test-Path -LiteralPath $paths.Guard) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $paths.Guard -Mode restore | Out-Null
    }
}

function Get-WindowSpan {
    param($Config)
    $start = [datetime]::ParseExact($Config.StartTime, 'HH:mm', $null)
    $end   = [datetime]::ParseExact($Config.EndTime, 'HH:mm', $null)
    if ($end -le $start) { $end = $end.AddDays(1) }
    $span = $end - $start
    if ($span.TotalMinutes -lt 5) { $span = [TimeSpan]::FromMinutes(5) }
    return $span
}

function Register-Lock {
    param($Config)

    $paths = Get-RuntimePaths
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $user  = "$env:USERDOMAIN\$env:USERNAME"

    foreach ($legacy in $LegacyTasks) {
        try { Unregister-ScheduledTask -TaskName $legacy -Confirm:$false -ErrorAction Stop } catch { }
    }

    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)

    $startAction = New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $paths.Guard + '" -Mode lock')
    $startTrigger = New-ScheduledTaskTrigger -Daily -At $Config.StartTime
    Register-ScheduledTask -TaskName $TaskStart -Action $startAction -Trigger $startTrigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    $stopAction = New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $paths.Guard + '" -Mode restore')
    $stopTrigger = New-ScheduledTaskTrigger -Daily -At $Config.EndTime
    Register-ScheduledTask -TaskName $TaskStop -Action $stopAction -Trigger $stopTrigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    $span = Get-WindowSpan -Config $Config
    $patrolAction = New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $paths.Guard + '" -Mode supervise')
    $patrolDaily = New-ScheduledTaskTrigger -Daily -At $Config.StartTime
    $patrolDaily.Repetition = (New-ScheduledTaskTrigger -Once -At $Config.StartTime `
        -RepetitionInterval (New-TimeSpan -Minutes ([int]$Config.PatrolMinutes)) `
        -RepetitionDuration $span).Repetition
    $patrolLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
    Register-ScheduledTask -TaskName $TaskPatrol -Action $patrolAction -Trigger @($patrolDaily, $patrolLogon) `
        -Settings $settings -Principal $principal -Force | Out-Null

    # the reminder before the window is gone: with a rotating password it cannot carry a usable one
    try { Unregister-ScheduledTask -TaskName $TaskNotify -Confirm:$false -ErrorAction Stop } catch { }
}

function Unregister-Lock {
    foreach ($name in @($TaskStart, $TaskStop, $TaskPatrol, $TaskNotify)) {
        try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop } catch { }
    }
}

function Get-StatusLines {
    $config = Get-AppConfig
    if (-not $config) { return @('尚未安装或配置文件缺失') }
    $running = @(Get-LockProcesses)
    $lines = @()
    $lines += ('锁电脑功能：' + $(if (Test-Installed) { '已启用' } else { '未启用（点“启用锁电脑”生效）' }))
    $lines += ('生效时段：每天 ' + $config.StartTime + ' 到次日 ' + $config.EndTime)
    $lines += ('巡查间隔：每 ' + $config.PatrolMinutes + ' 分钟检查一次')
    if ($config.EnablePassword) {
        $len = ([string]$config.UnlockPassword).Length
        $lines += ('应急口令：已启用（' + $len + ' 位）')
    } else {
        $lines += '应急口令：已关闭（只能插 U 盘解锁，或等到时段结束）'
    }
    return $lines
}

function Install-NightLock {
    param([switch]$NoArm)
    Write-Host '正在安装 NightLock ...'
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    $sameFolder = ($SourceDir.TrimEnd('\') -ieq $InstallDir.TrimEnd('\'))
    if (-not $sameFolder) {
        foreach ($file in @('guard.ps1', 'NightLock.ps1', 'night-lock.png', 'nightlock.ico', 'notify.ps1')) {
            $src = Join-Path $SourceDir $file
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $file) -Force }
        }
        $srcCfg = Join-Path $SourceDir 'config.json'
        if ((Test-Path -LiteralPath $srcCfg) -and -not (Test-Path -LiteralPath (Join-Path $InstallDir 'config.json'))) {
            Copy-Item -LiteralPath $srcCfg -Destination (Join-Path $InstallDir 'config.json') -Force
        }
    }

    $config = Get-AppConfig
    if (-not $config) { $config = New-DefaultConfig -BaseDir $InstallDir -Password (New-RandomPassword) }

    if (-not $config.UnlockPassword) {
        foreach ($legacy in $LegacyConfigs) {
            if (-not (Test-Path -LiteralPath $legacy)) { continue }
            try {
                $old = Get-Content -LiteralPath $legacy -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($old.UnlockPassword) {
                    $config.UnlockPassword = [string]$old.UnlockPassword
                    Write-Host '已沿用原来的应急口令'
                    break
                }
            } catch { }
        }
    }
    if (-not $config.UnlockPassword) {
        $config.UnlockPassword = New-RandomPassword
        Write-Host ('新生成的应急口令：' + $config.UnlockPassword)
    }
    $config.ImagePath = Join-Path $InstallDir 'night-lock.png'
    Save-AppConfig -Config $config

    try { Stop-LockNow } catch { }
    if ($NoArm) {
        Unregister-Lock
        Write-Host '按要求：只安装文件，暂不登记计划任务（不会自动锁屏）'
    } else {
        Register-Lock -Config $config
    }

    Write-Host ('安装完成：' + $InstallDir)
    Write-Host ('生效时段：' + $config.StartTime + ' - ' + $config.EndTime)

    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"' + (Join-Path $InstallDir 'NightLock.ps1') + '"')
    ) -WindowStyle Hidden
}

if ($Install) {
    Install-NightLock -NoArm:$NoArm
    exit 0
}

if ($StopNow) {
    Stop-LockNow
    Unregister-Lock
    Write-Host 'NightLock 已停止，计划任务已删除。'
    exit 0
}

foreach ($dir in @((Get-RuntimeDir), $SourceDir)) {
    $notifyPath = Join-Path $dir 'notify.ps1'
    if (Test-Path -LiteralPath $notifyPath) { . $notifyPath; break }
}

$channelKeys = @('none', 'dingtalk', 'wecom', 'feishu', 'qqmail')
$channelNames = @{
    none     = '不推送通知'
    dingtalk = '钉钉'
    wecom    = '企业微信'
    feishu   = '飞书'
    qqmail   = 'QQ邮箱'
}

function Get-SetupWarning {
    param($Config)
    $passwordOn = [bool]$Config.EnablePassword
    $pushOn = ($Config.Notify -and $Config.Notify.Enabled)
    $wait = 0
    if ($Config.PSObject.Properties.Name -contains 'WaitUnlockMinutes') { $wait = [int]$Config.WaitUnlockMinutes }
    $channelText = '通知'
    if ($pushOn) {
        $key = [string]$Config.Notify.Channel
        if ($channelNames.ContainsKey($key)) { $channelText = $channelNames[$key] }
    }

    if ($passwordOn -and -not $pushOn -and $wait -le 0) {
        return @{ Kind = 'error'; Text = '警告：口令不会发到手机，锁屏时只能用 U 盘解锁，或等早上自动解除' }
    }
    if ($passwordOn -and -not $pushOn) {
        return @{ Kind = 'warn'; Text = ('提示：口令不会发到手机，锁屏时只能用 U 盘解锁（当前等待时长 ' + $wait + ' 分钟）或 U 盘') }
    }
    if (-not $passwordOn -and $pushOn) {
        return @{ Kind = 'warn'; Text = '提示：应急口令已关闭，推送内容不会再包含口令' }
    }
    if ($passwordOn -and $pushOn) {
        return @{ Kind = 'info'; Text = ('设置已保存，口令会在锁定时推送到手机（' + $channelText + '）') }
    }
    return $null
}

# ------------------------------------------------------------ authority ------

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $MyInvocation.MyCommand.Path + '"')
        )
        exit 0
    } catch { }
}

# ------------------------------------------------------------------ gui ------

try {
    Add-Type -Namespace NightLockDpi -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    [void][NightLockDpi.Api]::SetProcessDPIAware()
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -Namespace NightLockIcon -Name Api -MemberDefinition @'
[DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr LoadImage(System.IntPtr hinst, string lpszName, uint uType, int cxDesired, int cyDesired, uint fuLoad);
[DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
'@

$nlRefs = @(
    [System.Drawing.Bitmap].Assembly.Location,
    [System.Windows.Forms.Button].Assembly.Location,
    [System.Object].Assembly.Location
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace NLUI
{
    public static class Draw
    {
        public static GraphicsPath Round(Rectangle r, int radius)
        {
            GraphicsPath p = new GraphicsPath();
            int d = radius * 2;
            if (d <= 1) { p.AddRectangle(r); return p; }
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    public class Card : Panel
    {
        public int Radius = 14;
        public string Title = "";
        public Color FillColor = Color.White;
        public Color BorderColor = Color.FromArgb(227, 232, 240);
        public Color TitleColor = Color.FromArgb(30, 41, 59);
        public bool ShowShadow = true;
        public List<Rectangle> Fields = new List<Rectangle>();
        private Font _titleFont;

        public Card()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(243, 245, 249);
            _titleFont = new Font("Microsoft YaHei UI", 11f, FontStyle.Bold);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(BackColor);

            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            if (ShowShadow && Width > 8 && Height > 8)
            {
                using (GraphicsPath sp = Draw.Round(new Rectangle(1, 3, Width - 3, Height - 3), Radius))
                using (SolidBrush sb = new SolidBrush(Color.FromArgb(16, 15, 23, 42)))
                {
                    g.FillPath(sb, sp);
                }
            }

            using (GraphicsPath path = Draw.Round(r, Radius))
            {
                if (Fields != null)
                {
                    foreach (Rectangle f in Fields)
                    {
                        if (f.Width <= 0 || f.Height <= 0) continue;
                        using (GraphicsPath fp = Draw.Round(f, 9))
                        using (SolidBrush fb = new SolidBrush(Color.White))
                        {
                            g.FillPath(fb, fp);
                        }
                        using (GraphicsPath fp2 = Draw.Round(f, 9))
                        using (Pen pen = new Pen(Color.FromArgb(224, 230, 239), 1f))
                        {
                            g.DrawPath(pen, fp2);
                        }
                    }
                }

                using (SolidBrush b = new SolidBrush(FillColor)) { g.FillPath(b, path); }
                using (Pen pen = new Pen(BorderColor, 1f)) { g.DrawPath(pen, path); }
            }

            if (!string.IsNullOrEmpty(Title))
            {
                using (SolidBrush b = new SolidBrush(TitleColor))
                {
                    g.DrawString(Title, _titleFont, b, 18, 11);
                }
            }
            base.OnPaint(e);
        }
    }

    public class RoundButton : Button
    {
        public int Radius = 10;
        public Color Fill = Color.White;
        public Color HoverFill = Color.FromArgb(240, 244, 252);
        public Color BorderColor = Color.FromArgb(222, 228, 238);
        public Color TextColor = Color.FromArgb(30, 41, 59);
        public Color DisabledTextColor = Color.FromArgb(160, 168, 180);
        private bool _hover = false;

        public RoundButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            BackColor = Color.White;
            Font = new Font("Microsoft YaHei UI", 10.5f);
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(BackColor);

            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            Color fill = Enabled ? (_hover ? HoverFill : Fill) : Color.FromArgb(246, 247, 250);
            using (GraphicsPath path = Draw.Round(r, Radius))
            {
                using (SolidBrush b = new SolidBrush(fill)) { g.FillPath(b, path); }
                if (BorderColor != Color.Transparent)
                {
                    using (Pen pen = new Pen(Enabled ? BorderColor : Color.FromArgb(235, 238, 244), 1f)) { g.DrawPath(pen, path); }
                }
            }
            TextRenderer.DrawText(g, Text, Font, r, Enabled ? TextColor : DisabledTextColor,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }
}
'@ -ReferencedAssemblies $nlRefs -ErrorAction Stop

$form = New-Object System.Windows.Forms.Form
$form.Text = '晚安 · 控制面板'
$form.ClientSize = New-Object System.Drawing.Size(760, 892)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

# ---- visual palette --------------------------------------------------------
$themes = @{
    day = @{
        Bg = [System.Drawing.Color]::FromArgb(243, 245, 249)
        Card = [System.Drawing.Color]::White
        CardBorder = [System.Drawing.Color]::FromArgb(226, 232, 240)
        Text = [System.Drawing.Color]::FromArgb(24, 33, 47)
        Muted = [System.Drawing.Color]::FromArgb(100, 116, 139)
        Border = [System.Drawing.Color]::FromArgb(216, 223, 234)
        Accent = [System.Drawing.Color]::FromArgb(37, 99, 235)
        AccentHover = [System.Drawing.Color]::FromArgb(29, 78, 216)
        AccentText = [System.Drawing.Color]::White
        Hover = [System.Drawing.Color]::FromArgb(238, 242, 255)
        Danger = [System.Drawing.Color]::FromArgb(203, 40, 40)
        DangerBorder = [System.Drawing.Color]::FromArgb(240, 195, 195)
        LogBg = [System.Drawing.Color]::FromArgb(249, 250, 252)
        LogText = [System.Drawing.Color]::FromArgb(51, 65, 85)
        Warn = [System.Drawing.Color]::FromArgb(200, 110, 0)
    }
    night = @{
        Bg = [System.Drawing.Color]::FromArgb(15, 20, 32)
        Card = [System.Drawing.Color]::FromArgb(24, 30, 46)
        CardBorder = [System.Drawing.Color]::FromArgb(44, 55, 78)
        Text = [System.Drawing.Color]::FromArgb(230, 235, 245)
        Muted = [System.Drawing.Color]::FromArgb(150, 162, 186)
        Border = [System.Drawing.Color]::FromArgb(52, 64, 90)
        Accent = [System.Drawing.Color]::FromArgb(76, 141, 255)
        AccentHover = [System.Drawing.Color]::FromArgb(58, 120, 235)
        AccentText = [System.Drawing.Color]::White
        Hover = [System.Drawing.Color]::FromArgb(34, 44, 66)
        Danger = [System.Drawing.Color]::FromArgb(255, 120, 120)
        DangerBorder = [System.Drawing.Color]::FromArgb(92, 60, 68)
        LogBg = [System.Drawing.Color]::FromArgb(18, 24, 38)
        LogText = [System.Drawing.Color]::FromArgb(178, 190, 210)
        Warn = [System.Drawing.Color]::FromArgb(240, 175, 80)
    }
}
$script:themeName = 'day'
$palette = @{}
foreach ($k in $themes.day.Keys) { $palette[$k] = $themes.day[$k] }
$form.BackColor = $palette.Bg

# window title bar + taskbar icon, loaded from the matching .ico sizes
$iconFile = Join-Path (Get-RuntimeDir) 'nightlock.ico'
if (Test-Path -LiteralPath $iconFile) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconFile, 48, 48) } catch { }
}

$applyWindowIcons = {
    if (-not (Test-Path -LiteralPath $iconFile)) { return }
    try {
        $IMAGE_ICON = 1
        $LR_LOADFROMFILE = 0x10
        $WM_SETICON = 0x0080
        $small = [NightLockIcon.Api]::LoadImage([System.IntPtr]::Zero, $iconFile, $IMAGE_ICON, 16, 16, $LR_LOADFROMFILE)
        $big   = [NightLockIcon.Api]::LoadImage([System.IntPtr]::Zero, $iconFile, $IMAGE_ICON, 48, 48, $LR_LOADFROMFILE)
        if ($small -ne [System.IntPtr]::Zero) { [void][NightLockIcon.Api]::SendMessage($form.Handle, $WM_SETICON, [System.IntPtr]0, $small) }
        if ($big   -ne [System.IntPtr]::Zero) { [void][NightLockIcon.Api]::SendMessage($form.Handle, $WM_SETICON, [System.IntPtr]1, $big) }
    } catch { }
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 70, [int]$H = 24, $Parent, [switch]$Wrap)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $false
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.ForeColor = $palette.Text
    $l.Tag = 'text'
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $l.SetBounds($X, $Y, $W, $H)
    $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    if ($Parent) { $Parent.Controls.Add($l) }
    if (-not $Wrap) {
        try {
            $g = $l.CreateGraphics()
            $need = [int][math]::Ceiling($g.MeasureString($Text, $l.Font).Width) + 6
            $g.Dispose()
            if ($need -gt $W) { $l.Width = $need }
        } catch { }
    }
    return $l
}

function New-Combo {
    param([int]$X, [int]$Y, [int[]]$Values, $Parent)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle = 'Flat'
    $c.BackColor = $palette.Card
    $c.ForeColor = $palette.Text
    $c.Tag = 'input'
    $c.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
    $c.SetBounds($X, $Y, 64, 26)
    foreach ($v in $Values) { [void]$c.Items.Add($v.ToString('00')) }
    $Parent.Controls.Add($c)
    return $c
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 160, [int]$H = 38, $Parent,
          [ValidateSet('normal', 'primary', 'danger')][string]$Kind = 'normal')
    $b = New-Object NLUI.RoundButton
    $b.Text = $Text
    $b.SetBounds($X, $Y, $W, $H)
    $b.BackColor = $palette.Card
    $b.Radius = 10
    $b.Tag = $Kind
    switch ($Kind) {
        'primary' {
            $b.Fill = $palette.Accent
            $b.HoverFill = [System.Drawing.Color]::FromArgb(29, 78, 216)
            $b.BorderColor = $palette.Accent
            $b.TextColor = [System.Drawing.Color]::White
        }
        'danger' {
            $b.Fill = $palette.Card
            $b.HoverFill = [System.Drawing.Color]::FromArgb(254, 242, 242)
            $b.BorderColor = [System.Drawing.Color]::FromArgb(240, 190, 190)
            $b.TextColor = $palette.Danger
        }
        default {
            $b.Fill = $palette.Card
            $b.HoverFill = $palette.Hover
            $b.BorderColor = $palette.Border
            $b.TextColor = $palette.Text
        }
    }
    $Parent.Controls.Add($b)
    return $b
}

# --- status -----------------------------------------------------------------

$statusBox = New-Object NLUI.Card
$statusBox.Title = ''
$statusBox.Radius = 14
$statusBox.SetBounds(16, 12, 728, 140)
$form.Controls.Add($statusBox)

$statusTitle = New-Object System.Windows.Forms.Label
$statusTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
$statusTitle.SetBounds(16, 26, 556, 28)
$statusTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusBox.Controls.Add($statusTitle)

$btnTheme = New-Button -Text '主题：白天' -X 582 -Y 20 -W 130 -H 32 -Parent $statusBox

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9.5)
$statusLabel.AutoSize = $false
$statusLabel.SetBounds(16, 58, 696, 74)
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$statusBox.Controls.Add($statusLabel)

# --- settings ---------------------------------------------------------------

$setupBox = New-Object NLUI.Card
$setupBox.Title = '锁屏时段'
$setupBox.Radius = 14
$setupBox.SetBounds(16, 164, 728, 228)
$form.Controls.Add($setupBox)

$lblStart = New-Label -Text '开始时间' -X 16 -Y 34 -W 70 -Parent $setupBox
$cmbStartHour = New-Combo -X ($lblStart.Right + 8) -Y 30 -Values (0..23) -Parent $setupBox
$lblColon1 = New-Label -Text ':' -X ($cmbStartHour.Right + 4) -Y 34 -W 12 -Parent $setupBox
$cmbStartMin  = New-Combo -X ($lblColon1.Right + 4) -Y 30 -Values (0..59) -Parent $setupBox

$lblEnd = New-Label -Text '结束时间' -X ($cmbStartMin.Right + 30) -Y 34 -W 70 -Parent $setupBox
$cmbEndHour = New-Combo -X ($lblEnd.Right + 8) -Y 30 -Values (0..23) -Parent $setupBox
$lblColon2 = New-Label -Text ':' -X ($cmbEndHour.Right + 4) -Y 34 -W 12 -Parent $setupBox
$cmbEndMin  = New-Combo -X ($lblColon2.Right + 4) -Y 30 -Values (0..59) -Parent $setupBox

$lblPatrol = New-Label -Text '巡查间隔' -X 16 -Y 76 -W 70 -Parent $setupBox
$numPatrol = New-Object System.Windows.Forms.NumericUpDown
$numPatrol.Minimum = 1
$numPatrol.Maximum = 60
$numPatrol.SetBounds(($lblPatrol.Right + 8), 72, 68, 26)
$setupBox.Controls.Add($numPatrol)
[void](New-Label -Text '分钟检查一次（越小越难绕过）' -X ($numPatrol.Right + 12) -Y 76 -W 330 -Parent $setupBox)

$chkPassword = New-Object System.Windows.Forms.CheckBox
$chkPassword.Text = '启用应急口令'
$chkPassword.SetBounds(16, 112, 240, 26)
$setupBox.Controls.Add($chkPassword)

$txtPassword = New-Object System.Windows.Forms.TextBox
$txtPassword.SetBounds(270, 111, 300, 26)
$txtPassword.Font = New-Object System.Drawing.Font('Consolas', 10)
$setupBox.Controls.Add($txtPassword)

$btnRandom = New-Button -Text '随机生成' -X 582 -Y 109 -W 110 -H 30 -Parent $setupBox

$lblImage = New-Label -Text '锁屏图片' -X 16 -Y 156 -W 70 -Parent $setupBox
$txtImage = New-Object System.Windows.Forms.TextBox
$txtImage.SetBounds(($lblImage.Right + 8), 155, 520, 26)
$setupBox.Controls.Add($txtImage)
$btnBrowse = New-Button -Text '浏览…' -X ($txtImage.Right + 10) -Y 153 -W 78 -H 30 -Parent $setupBox

$previewLabel = New-Label -Text '' -X 16 -Y 192 -W 690 -H 26 -Parent $setupBox
$previewLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)

# --- actions ----------------------------------------------------------------

$actionBox = New-Object NLUI.Card
$actionBox.Title = '操作'
$actionBox.Radius = 14
$actionBox.SetBounds(16, 404, 728, 272)
$form.Controls.Add($actionBox)

$btnEnable  = New-Button -Text '启用锁电脑'     -X 16  -Y 30 -W 168 -H 40 -Parent $actionBox -Kind primary
$btnStop    = New-Button -Text '停止并解除'     -X 192 -Y 30 -W 168 -H 40 -Parent $actionBox
$btnPreview = New-Button -Text '预览锁屏 30 秒' -X 368 -Y 30 -W 168 -H 40 -Parent $actionBox
$btnSave    = New-Button -Text '保存设置'       -X 544 -Y 30 -W 168 -H 40 -Parent $actionBox -Kind primary

$lblForce = New-Label -Text '立即锁定' -X 16 -Y 90 -W 70 -Parent $actionBox
$numForce = New-Object System.Windows.Forms.NumericUpDown
$numForce.Minimum = 1
$numForce.Maximum = 720
$numForce.Value = 30
$numForce.SetBounds(($lblForce.Right + 8), 86, 68, 26)
$actionBox.Controls.Add($numForce)
$lblMinutes = New-Label -Text '分钟' -X ($numForce.Right + 8) -Y 90 -W 44 -Parent $actionBox
$btnForce = New-Button -Text '现在就开始锁' -X ($lblMinutes.Right + 12) -Y 86 -W 140 -H 34 -Parent $actionBox -Kind primary
$btnFolder = New-Button -Text '打开程序文件夹' -X ($btnForce.Right + 8) -Y 86 -W 150 -H 34 -Parent $actionBox
$btnLog = New-Button -Text '记事本打开日志' -X ($btnFolder.Right + 8) -Y 86 -W 150 -H 34 -Parent $actionBox

$btnRemove = New-Button -Text '完全卸载（删除计划任务）' -X 16 -Y 134 -W 250 -H 38 -Parent $actionBox -Kind danger
[void](New-Label -Text '修改时段后点“保存设置”，会自动重新登记计划任务。' -X 280 -Y 134 -W 276 -H 48 -Parent $actionBox -Wrap)
$btnDefaultTime = New-Button -Text '恢复默认时段' -X 572 -Y 134 -W 140 -H 38 -Parent $actionBox

$note = New-Object System.Windows.Forms.Label
$note.Text = '锁住时可按 Esc 15 秒输口令解锁，也可插 U 盘（里面有 NIGHTGUARD-UNLOCK.txt），锁屏右下角还有关机 / 重启按钮。'
$note.ForeColor = [System.Drawing.Color]::DimGray
$note.AutoSize = $false
$note.SetBounds(16, 216, 696, 44)
$actionBox.Controls.Add($note)

$noticeLabel = New-Object System.Windows.Forms.Label
$noticeLabel.Text = ''
$noticeLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
$noticeLabel.AutoSize = $false
$noticeLabel.SetBounds(16, 184, 696, 28)
$actionBox.Controls.Add($noticeLabel)

# --- live log ---------------------------------------------------------------

# --- tabs: lock settings / notifications ------------------------------------

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.SetBounds(16, 162, 728, 546)
$form.Controls.Add($tabs)

$pageLock = New-Object System.Windows.Forms.TabPage
$pageLock.Text = '锁屏设置'
$tabs.Controls.Add($pageLock)

$pageNotify = New-Object System.Windows.Forms.TabPage
$pageNotify.Text = '通知与解锁'
$tabs.Controls.Add($pageNotify)

$form.Controls.Remove($setupBox)
$pageLock.Controls.Add($setupBox)
$setupBox.SetBounds(4, 8, 712, 360)

$form.Controls.Remove($actionBox)
$pageLock.Controls.Add($actionBox)
$actionBox.SetBounds(4, 376, 712, 130)

# --- notification page ------------------------------------------------------

[void](New-Label -Text '通知方式' -X 12 -Y 18 -W 110 -Parent $pageNotify)
$cmbChannel = New-Object System.Windows.Forms.ComboBox
$cmbChannel.DropDownStyle = 'DropDownList'
$cmbChannel.SetBounds(130, 14, 170, 26)
foreach ($item in @('不推送通知', '钉钉', '企业微信', '飞书', 'QQ邮箱')) { [void]$cmbChannel.Items.Add($item) }
$pageNotify.Controls.Add($cmbChannel)
$btnTest = New-Button -Text '发送测试消息' -X 312 -Y 12 -W 150 -H 30 -Parent $pageNotify -Kind primary
[void](New-Label -Text '填好参数后先测试一次' -X 474 -Y 18 -W 240 -Parent $pageNotify)

[void](New-Label -Text '机器人地址' -X 12 -Y 58 -W 110 -Parent $pageNotify)
$txtWebhook = New-Object System.Windows.Forms.TextBox
$txtWebhook.SetBounds(130, 54, 570, 26)
$pageNotify.Controls.Add($txtWebhook)

[void](New-Label -Text '加签密钥' -X 12 -Y 94 -W 110 -Parent $pageNotify)
$txtSecret = New-Object System.Windows.Forms.TextBox
$txtSecret.SetBounds(130, 90, 300, 26)
$pageNotify.Controls.Add($txtSecret)
[void](New-Label -Text '只有钉钉的加签模式需要填' -X 442 -Y 94 -W 260 -Parent $pageNotify)

[void](New-Label -Text '发件邮箱' -X 12 -Y 134 -W 110 -Parent $pageNotify)
$txtMailFrom = New-Object System.Windows.Forms.TextBox
$txtMailFrom.SetBounds(130, 130, 240, 26)
$pageNotify.Controls.Add($txtMailFrom)
[void](New-Label -Text '授权码' -X 386 -Y 134 -W 60 -Parent $pageNotify)
$txtAuthCode = New-Object System.Windows.Forms.TextBox
$txtAuthCode.UseSystemPasswordChar = $true
$txtAuthCode.SetBounds(450, 130, 250, 26)
$pageNotify.Controls.Add($txtAuthCode)

[void](New-Label -Text '收件邮箱' -X 12 -Y 174 -W 110 -Parent $pageNotify)
$txtMailTo = New-Object System.Windows.Forms.TextBox
$txtMailTo.SetBounds(130, 170, 300, 26)
$pageNotify.Controls.Add($txtMailTo)
[void](New-Label -Text '多个收件人用逗号分隔' -X 442 -Y 174 -W 260 -Parent $pageNotify)

[void](New-Label -Text '推送时机' -X 12 -Y 214 -W 110 -Parent $pageNotify)
[void](New-Label -Text '锁屏前' -X 130 -Y 214 -W 60 -Parent $pageNotify)
$numBefore = New-Object System.Windows.Forms.NumericUpDown
$numBefore.Minimum = 0
$numBefore.Maximum = 120
$numBefore.Value = 5
$numBefore.SetBounds(196, 210, 60, 26)
$pageNotify.Controls.Add($numBefore)
[void](New-Label -Text '分钟推送口令' -X 266 -Y 214 -W 130 -Parent $pageNotify)
$chkOnLock = New-Object System.Windows.Forms.CheckBox
$chkOnLock.Text = '每次锁屏开始时推送'
$chkOnLock.Checked = $true
$chkOnLock.SetBounds(410, 212, 260, 26)
$pageNotify.Controls.Add($chkOnLock)

[void](New-Label -Text '等待解锁' -X 12 -Y 254 -W 110 -Parent $pageNotify)
$numWait = New-Object System.Windows.Forms.NumericUpDown
$numWait.Minimum = 0
$numWait.Maximum = 240
$numWait.Value = 20
$numWait.SetBounds(130, 250, 60, 26)
$pageNotify.Controls.Add($numWait)
[void](New-Label -Text '分钟后锁屏界面上出现“可解锁”按钮，0 = 关闭' -X 200 -Y 254 -W 480 -Parent $pageNotify)

$notifyHelp = New-Object System.Windows.Forms.Label
$notifyHelp.AutoSize = $false
$notifyHelp.ForeColor = [System.Drawing.Color]::DimGray
$notifyHelp.Text = '通知只是锁屏的附加功能：要先在“锁屏设置”标签页点“启用锁电脑”，这里设置的通知才会真正生效；这里选“不推送通知”时，电脑照样会锁，只是不会给你发消息。' + "`r`n" + '钉钉 / 企业微信 / 飞书：在群里添加自定义机器人，把 webhook 地址粘到“机器人地址”里。QQ 邮箱：在网页版邮箱设置里开启 SMTP 服务并生成授权码，填到“授权码”里。填好后先点“发送测试消息”确认能收到。'
$notifyHelp.SetBounds(12, 292, 676, 150)
$pageNotify.Controls.Add($notifyHelp)

$logGroup = New-Object NLUI.Card
$logGroup.Title = '运行日志 · 最近 200 行，自动滚动'
$logGroup.Radius = 14
$logGroup.SetBounds(16, 716, 728, 160)
$form.Controls.Add($logGroup)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.WordWrap = $false
$logBox.ScrollBars = 'Vertical'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$logBox.SetBounds(14, 24, 700, 126)
$logGroup.Controls.Add($logBox)

$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 2000
$script:lastLogCount = 0

function Update-LogView {
    param([switch]$Force)
    try {
        $paths = Get-RuntimePaths
        if (-not (Test-Path -LiteralPath $paths.Log)) {
            if ($Force) { $logBox.Text = '（还没有日志）' }
            return
        }
        $lines = @(Get-Content -LiteralPath $paths.Log -Encoding UTF8)
        if ($lines.Count -eq $script:lastLogCount -and -not $Force) { return }
        if ($lines.Count -lt $script:lastLogCount) { $logBox.Clear() }
        if ($Force -or $script:lastLogCount -eq 0) {
            $logBox.Clear()
            $start = [math]::Max(0, $lines.Count - 200)
        } else {
            $start = $script:lastLogCount
        }
        for ($i = $start; $i -lt $lines.Count; $i++) { $logBox.AppendText($lines[$i] + "`r`n") }
        $script:lastLogCount = $lines.Count
        if ($logBox.TextLength -gt 0) {
            $logBox.SelectionStart = $logBox.TextLength
            $logBox.ScrollToCaret()
        }
        if ($Force) { Write-AppLog ('log view filled: ' + $lines.Count + ' lines, box length ' + $logBox.TextLength) }
    } catch {
        Write-AppLog ('log view error: ' + $_.Exception.Message)
    }
}

$logTimer.Add_Tick({ Update-LogView })

# --- behaviour --------------------------------------------------------------

$refresh = {
    $lines = @(Get-StatusLines)
    $running = (@(Get-LockProcesses).Count -gt 0)
    if (Test-Installed) {
        $statusTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 140, 60)
        $statusTitle.Text = '运行状态：已启用'
    } else {
        $statusTitle.ForeColor = [System.Drawing.Color]::FromArgb(200, 30, 30)
        $statusTitle.Text = '运行状态：未启用'
    }
    $statusLabel.Text = (($lines | Select-Object -Skip 1) -join "`r`n")
    try { & $updateToggle } catch { }
}

$loadConfig = {
    $script:loadingConfig = $true
    $config = Get-AppConfig
    if (-not $config) { $script:loadingConfig = $false; return }
    $startParts = ([string]$config.StartTime).Split(':')
    $endParts   = ([string]$config.EndTime).Split(':')
    $cmbStartHour.SelectedItem = $startParts[0]
    $cmbStartMin.SelectedItem  = if ($startParts.Count -gt 1) { $startParts[1] } else { '00' }
    $cmbEndHour.SelectedItem   = $endParts[0]
    $cmbEndMin.SelectedItem    = if ($endParts.Count -gt 1) { $endParts[1] } else { '00' }
    $pm = [int]$config.PatrolMinutes
    if ($pm -lt 1) { $pm = 1 }
    $cmbPatrolHour.SelectedItem = ([int]($pm / 60)).ToString('00')
    $cmbPatrolMin.SelectedItem = ($pm % 60).ToString('00')
    $chkPassword.Checked = [bool]$config.EnablePassword
    $txtPassword.Text = [string]$config.UnlockPassword
    $txtImage.Text = [string]$config.ImagePath
    # wait-unlock was removed; always keep it off
    $numWait.Value = 0
    if ($config.PSObject.Properties.Name -contains 'RotatePassword') {
        $chkRotate.Checked = [bool]$config.RotatePassword
    } else {
        $chkRotate.Checked = $true
    }
    if ($config.Notify) {
        $n = $config.Notify
        $idx = [array]::IndexOf($channelKeys, [string]$n.Channel)
        if ($idx -lt 0) { $idx = 0 }
        $cmbChannel.SelectedIndex = $idx
        $txtWebhook.Text   = [string]$n.Webhook
        $txtSecret.Text    = [string]$n.Secret
        $txtMailFrom.Text  = [string]$n.MailFrom
        $txtAuthCode.Text  = [string]$n.MailAuthCode
        $txtMailTo.Text    = [string]$n.MailTo
        $numBefore.Value   = [int]$n.BeforeMinutes
        $chkOnLock.Checked = [bool]$n.OnLock
    }
    $script:loadingConfig = $false
    & $updatePreview
}

$collectConfig = {
    $config = Get-AppConfig
    if (-not $config) { $config = New-DefaultConfig -BaseDir (Get-RuntimeDir) -Password (New-RandomPassword) }
    $config.StartTime = ([string]$cmbStartHour.SelectedItem) + ':' + ([string]$cmbStartMin.SelectedItem)
    $config.EndTime   = ([string]$cmbEndHour.SelectedItem) + ':' + ([string]$cmbEndMin.SelectedItem)
    $ph = 0; $pm = 1
    if ($cmbPatrolHour.SelectedItem) { $ph = [int]$cmbPatrolHour.SelectedItem }
    if ($cmbPatrolMin.SelectedItem) { $pm = [int]$cmbPatrolMin.SelectedItem }
    $config.PatrolMinutes = [int](($ph * 60) + $pm)
    if ($config.PatrolMinutes -lt 1) { $config.PatrolMinutes = 1 }
    $config.EnablePassword = [bool]$chkPassword.Checked
    if ($txtPassword.Text.Trim().Length -gt 0) { $config.UnlockPassword = $txtPassword.Text.Trim() }
    if ($txtImage.Text.Trim().Length -gt 0) { $config.ImagePath = $txtImage.Text.Trim() }

    $channel = 'none'
    if ($cmbChannel.SelectedIndex -ge 0) { $channel = $channelKeys[[int]$cmbChannel.SelectedIndex] }
    $notify = [ordered]@{
        Enabled       = ($channel -ne 'none')
        Channel       = $channel
        Webhook       = $txtWebhook.Text.Trim()
        Secret        = $txtSecret.Text.Trim()
        MailFrom      = $txtMailFrom.Text.Trim()
        MailAuthCode  = $txtAuthCode.Text.Trim()
        MailTo        = $txtMailTo.Text.Trim()
        OnLock        = [bool]$chkOnLock.Checked
        BeforeMinutes = [int]$numBefore.Value
    }
    $config | Add-Member -NotePropertyName Notify -NotePropertyValue $notify -Force
    $config | Add-Member -NotePropertyName WaitUnlockMinutes -NotePropertyValue ([int]$numWait.Value) -Force
    $config | Add-Member -NotePropertyName RotatePassword -NotePropertyValue ([bool]$chkRotate.Checked) -Force
    return $config
}

$updatePreview = {
    if ($script:loadingConfig) { return }
    $s = ([string]$cmbStartHour.SelectedItem) + ':' + ([string]$cmbStartMin.SelectedItem)
    $e = ([string]$cmbEndHour.SelectedItem) + ':' + ([string]$cmbEndMin.SelectedItem)
    $saved = Get-AppConfig
    $changed = $false
    if ($saved) {
        if ($saved.StartTime -ne $s -or $saved.EndTime -ne $e) { $changed = $true }
    }
    if ($changed) {
        try { Set-Notice ('时段已改成 ' + $s + ' - ' + $e + '，点“保存设置”才会生效') 'warn' } catch { }
    }
}

$cmbStartHour.Add_SelectedIndexChanged($updatePreview)
$cmbStartMin.Add_SelectedIndexChanged($updatePreview)
$cmbEndHour.Add_SelectedIndexChanged($updatePreview)
$cmbEndMin.Add_SelectedIndexChanged($updatePreview)

$btnDefaultTime.Add_Click({
    $cmbStartHour.SelectedItem = '23'
    $cmbStartMin.SelectedItem  = '00'
    $cmbEndHour.SelectedItem   = '06'
    $cmbEndMin.SelectedItem    = '00'
    Set-Notice '已恢复为 23:00 到 06:00，点“保存设置”生效。' 'warn'
})

$noticeTimer = New-Object System.Windows.Forms.Timer
$noticeTimer.Interval = 9000
$script:confirmStop = $false
$script:confirmRemove = $false

function Set-Notice {
    param([string]$Text, [string]$Kind = 'info')
    try { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default } catch { }
    if ($Kind -eq 'error') {
        $noticeLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 30, 30)
    } elseif ($Kind -eq 'warn') {
        $noticeLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 110, 0)
    } else {
        $noticeLabel.ForeColor = [System.Drawing.Color]::FromArgb(15, 110, 60)
    }
    $noticeLabel.Text = $Text
    $noticeTimer.Stop()
    $noticeTimer.Start()
}

function Set-Working {
    param([string]$Text)
    $noticeLabel.ForeColor = $palette.Warn
    $noticeLabel.Text = $Text
    $noticeTimer.Stop()
    try { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor } catch { }
    # force an immediate repaint, otherwise the frozen UI hides this message
    $noticeLabel.Refresh()
}

# the engine rotates the password while the panel may be open: keep the box truthful
$pwdSyncTimer = New-Object System.Windows.Forms.Timer
$pwdSyncTimer.Interval = 10000
$pwdSyncTimer.Add_Tick({
    try {
        if (-not $txtPassword.Focused) {
            $cfg = Get-AppConfig
            if ($cfg -and $cfg.UnlockPassword -and ([string]$cfg.UnlockPassword -ne $txtPassword.Text)) {
                $txtPassword.Text = [string]$cfg.UnlockPassword
                Write-AppLog 'password field refreshed from config'
            }
        }
    } catch { }
})

$noticeTimer.Add_Tick({
    $noticeTimer.Stop()
    $noticeLabel.Text = ''
    if ($script:confirmStop) { $script:confirmStop = $false; $btnStop.Text = '停止并解除' }
    if ($script:confirmRemove) { $script:confirmRemove = $false; $btnRemove.Text = '完全卸载（删除计划任务）' }
})

$btnSave.Add_Click({
    try {
        Set-Working '正在保存设置…'
        $config = & $collectConfig
        Save-AppConfig -Config $config
        Write-AppLog ('settings saved: ' + $config.StartTime + ' - ' + $config.EndTime + ', patrol ' + $config.PatrolMinutes + ' min')
        if (Test-Installed) {
            Register-Lock -Config $config
            Write-AppLog 'tasks re-registered after save'
            $warning = Get-SetupWarning -Config $config
            if ($warning) { Set-Notice $warning.Text $warning.Kind }
            else { Set-Notice ('设置已保存，计划任务已更新为 ' + $config.StartTime + ' - ' + $config.EndTime + '。') }
        } else {
            Set-Notice '设置已保存。点“启用锁电脑”后生效。' 'warn'
        }
    } catch {
        Write-AppLog ('save failed: ' + $_.Exception.Message)
        Set-Notice ('保存失败：' + $_.Exception.Message) 'error'
    }
    & $refresh
})

$btnEnable.Add_Click({
    try {
        if (Test-Installed) { Set-Working '正在停用…' } else { Set-Working '正在启用…' }
        if (Test-Installed) {
            Stop-LockNow
            Unregister-Lock
            Write-AppLog 'lock stopped by toggle'
            & $refresh
            Set-Notice '已停用：计划任务已删除，电脑可正常使用。再点一次即可重新启动。'
            return
        }
        $config = & $collectConfig
        $generated = ''
        if ($config.EnablePassword -and ([string]$config.UnlockPassword).Length -lt 8) {
            $config.UnlockPassword = New-RandomPassword
            $txtPassword.Text = $config.UnlockPassword
            $generated = $config.UnlockPassword
        }
        Save-AppConfig -Config $config
        Register-Lock -Config $config
        Write-AppLog 'lock enabled'
        & $refresh
        $warning = Get-SetupWarning -Config $config
        if ($warning) {
            if ($generated) { Set-Notice ($warning.Text + '；新口令：' + $generated) $warning.Kind }
            else { Set-Notice $warning.Text $warning.Kind }
        }
        elseif ($generated) {
            Set-Notice ('已启用。新口令：' + $generated + '（请抄下来）') 'warn'
        } else {
            Set-Notice ('已启用：每天 ' + $config.StartTime + ' 到 ' + $config.EndTime + ' 自动锁屏。')
        }
    } catch {
        Write-AppLog ('enable failed: ' + $_.Exception.Message)
        Set-Notice ('启用失败：' + $_.Exception.Message) 'error'
    }
})

$btnStop.Add_Click({
    try {
        if (-not $script:confirmStop) {
            $script:confirmStop = $true
            $btnStop.Text = '再点一次确认停止'
            Set-Notice '停止后计划任务会被删除，需要重新点“启用锁电脑”才会再次生效。' 'warn'
            return
        }
        $script:confirmStop = $false
        $btnStop.Text = '停止并解除'
        Stop-LockNow
        Unregister-Lock
        Write-AppLog 'lock stopped'
        & $refresh
        Set-Notice '已停止，电脑可正常使用，随时可以重新启用。'
    } catch {
        Write-AppLog ('stop failed: ' + $_.Exception.Message)
        Set-Notice ('停止失败：' + $_.Exception.Message) 'error'
    }
})

$btnPreview.Add_Click({
    try {
        Set-Working '正在启动预览…'
        $paths = Get-RuntimePaths
        $config = & $collectConfig
        Save-AppConfig -Config $config
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"' + $paths.Guard + '"'), '-Mode', 'lock', '-TestSeconds', '30', '-DryRunShutdown'
        ) -WindowStyle Hidden
        Write-AppLog 'preview started'
        Set-Notice '锁屏已启动，30 秒后自动解除（这次不会真的关机）。'
    } catch {
        Write-AppLog ('preview failed: ' + $_.Exception.Message)
        Set-Notice ('预览失败：' + $_.Exception.Message) 'error'
    }
})

$btnForce.Add_Click({
    try {
        Set-Working '正在锁定…'
        $fh = 0; $fm = 30
        if ($cmbForceHour.SelectedItem) { $fh = [int]$cmbForceHour.SelectedItem }
        if ($cmbForceMin.SelectedItem) { $fm = [int]$cmbForceMin.SelectedItem }
        $minutes = ($fh * 60) + $fm
        if ($minutes -lt 1) {
            Set-Notice '请先选择锁定时长（小时 : 分钟）' 'warn'
            return
        }
        $paths = Get-RuntimePaths
        $config = & $collectConfig
        Save-AppConfig -Config $config
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"' + $paths.Guard + '"'), '-Mode', 'lock', '-ForcedMinutes', ([string]$minutes)
        ) -WindowStyle Hidden
        Write-AppLog ('forced lock started for ' + $minutes + ' minutes')
        Set-Notice ('已开始锁定，' + $minutes + ' 分钟后自动解除。')
    } catch {
        Write-AppLog ('force lock failed: ' + $_.Exception.Message)
        Set-Notice ('锁定失败：' + $_.Exception.Message) 'error'
    }
})

$btnRandom.Add_Click({ $txtPassword.Text = New-RandomPassword })

$btnTest.Add_Click({
    try {
        Set-Working '正在发送测试消息…'
        $config = & $collectConfig
        # sending a test also commits the settings, so they survive closing the panel
        Save-AppConfig -Config $config
        $waitMin = 0
        if ($config.PSObject.Properties.Name -contains 'WaitUnlockMinutes') { $waitMin = [int]$config.WaitUnlockMinutes }
        $lines = @()
        $lines += '【晚安】测试消息'
        $lines += ('锁定时段：每天 ' + $config.StartTime + ' 到次日 ' + $config.EndTime)
        $lines += ('当前状态：' + $(if (Test-Installed) { '已启用' } else { '未启用' }))
        if ($config.EnablePassword) {
            $lines += ('应急口令：' + $config.UnlockPassword)
        } else {
            $lines += '应急口令：未启用'
        }
        $lines += ('等待解锁：' + $waitMin + ' 分钟后锁屏界面给出解锁按钮')
        $lines += ('巡查间隔：每 ' + $config.PatrolMinutes + ' 分钟检查一次')
        $body = ($lines -join "`r`n")
        $r = Send-Notify -Notify $config.Notify -Subject '【晚安】测试消息' -Body $body
        Write-AppLog ('notify test: ' + $r.Message)
        if ($r.Ok) { Set-Notice '测试消息已发出，去手机上看一眼。' }
        else { Set-Notice ('测试失败：' + $r.Message) 'error' }
    } catch {
        Write-AppLog ('notify test failed: ' + $_.Exception.Message)
        Set-Notice ('测试出错：' + $_.Exception.Message) 'error'
    }
})

$btnBrowse.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = '图片文件|*.png;*.jpg;*.jpeg;*.bmp'
        if ($dialog.ShowDialog() -eq 'OK') {
            $target = Join-Path (Get-RuntimeDir) 'night-lock-custom.png'
            Copy-Item -LiteralPath $dialog.FileName -Destination $target -Force
            $txtImage.Text = $target
        }
    } catch {
        Write-AppLog ('browse failed: ' + $_.Exception.Message)
    }
})

$btnFolder.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Get-RuntimeDir) + '"') })

$btnLog.Add_Click({
    $paths = Get-RuntimePaths
    if (Test-Path -LiteralPath $paths.Log) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $paths.Log + '"')
    } else {
        Set-Notice '还没有日志文件。' 'warn'
    }
})

$btnRemove.Add_Click({
    try {
        if (-not $script:confirmRemove) {
            $script:confirmRemove = $true
            $btnRemove.Text = '再点一次确认卸载'
            Set-Notice '卸载后计划任务会被删除，需要重新安装才能恢复。' 'warn'
            return
        }
        $script:confirmRemove = $false
        $btnRemove.Text = '完全卸载（删除计划任务）'
        Stop-LockNow
        Unregister-Lock
        Write-AppLog 'uninstalled'
        & $refresh
        Set-Notice ('已卸载。程序文件夹仍在 ' + (Get-RuntimeDir) + '，可以直接删除。')
    } catch {
        Write-AppLog ('uninstall failed: ' + $_.Exception.Message)
        Set-Notice ('卸载失败：' + $_.Exception.Message) 'error'
    }
})

$form.Add_Shown({
    & $loadConfig
    try { & $applyChannelPane } catch { }
    & $refresh
    & $applyWindowIcons
    $pwdSyncTimer.Start()
    $savedTheme = 'day'
    $cfgForTheme = Get-AppConfig
    if ($cfgForTheme -and ($cfgForTheme.PSObject.Properties.Name -contains 'Theme')) {
        $savedTheme = [string]$cfgForTheme.Theme
    } else {
        # no choice saved yet: follow the clock
        $h = (Get-Date).Hour
        if ($cfgForTheme) {
            $startH = [int]([string]$cfgForTheme.StartTime).Split(':')[0]
            $endH = [int]([string]$cfgForTheme.EndTime).Split(':')[0]
            if ($startH -gt $endH) { if ($h -ge $startH -or $h -lt $endH) { $savedTheme = 'night' } }
            elseif ($h -ge $startH -and $h -lt $endH) { $savedTheme = 'night' }
        }
    }
    if ($savedTheme -ne 'day' -and $savedTheme -ne 'night') { $savedTheme = 'day' }
    Apply-Theme $savedTheme
    Write-AppLog 'panel opened'
})

# closing the panel must not throw away edits made in the notification tab
$form.Add_FormClosing({
    param($sender, $e)
    try {
        $config = & $collectConfig
        Save-AppConfig -Config $config
        Write-AppLog 'settings auto saved on close'
    } catch { }
})

# ---- theme engine ----------------------------------------------------------

function Apply-Theme {
    param([string]$Name)
    if (-not $themes.ContainsKey($Name)) { $Name = 'day' }
    $script:themeName = $Name
    $t = $themes[$Name]
    foreach ($k in $t.Keys) { $palette[$k] = $t[$k] }

    $form.BackColor = $palette.Bg
    $tabs.BackColor = $palette.Card
    foreach ($page in @($pageLock, $pageNotify)) { $page.BackColor = $palette.Card }

    $walk = $null
    $walk = {
        param($parent)
        foreach ($c in $parent.Controls) {
            switch ([string]$c.Tag) {
                'card' {
                    $c.BackColor = $palette.Bg
                    $c.FillColor = $palette.Card
                    $c.BorderColor = $palette.CardBorder
                    $c.TitleColor = $palette.Text
                    $c.Invalidate()
                }
                'input' {
                    $c.BackColor = $palette.Card
                    $c.ForeColor = $palette.Text
                    if ($c -is [System.Windows.Forms.TextBox]) { $c.BorderStyle = 'FixedSingle' }
                    $c.Invalidate()
                }
                'primary' {
                    $c.BackColor = $palette.Card; $c.Fill = $palette.Accent
                    $c.HoverFill = $palette.AccentHover; $c.BorderColor = $palette.Accent
                    $c.TextColor = $palette.AccentText; $c.Invalidate()
                }
                'danger' {
                    $c.BackColor = $palette.Card; $c.Fill = $palette.Card
                    $c.HoverFill = $palette.Hover; $c.BorderColor = $palette.DangerBorder
                    $c.TextColor = $palette.Danger; $c.Invalidate()
                }
                'normal' {
                    $c.BackColor = $palette.Card; $c.Fill = $palette.Card
                    $c.HoverFill = $palette.Hover; $c.BorderColor = $palette.Border
                    $c.TextColor = $palette.Text; $c.Invalidate()
                }
                'muted' { $c.ForeColor = $palette.Muted; $c.Invalidate() }
                'link'  { $c.ForeColor = $palette.Accent; $c.Invalidate() }
                'text'  { $c.ForeColor = $palette.Text; $c.Invalidate() }
                default {
                    if ($c -is [System.Windows.Forms.TabPage]) { $c.BackColor = $palette.Card }
                    elseif ($c -is [System.Windows.Forms.TabControl]) { $c.BackColor = $palette.Card }
                }
            }
            $walk.Invoke($c)
        }
    }
    $walk.Invoke($form)

    $logBox.BackColor = $palette.LogBg
    $logBox.ForeColor = $palette.LogText
    $note.ForeColor = $palette.Muted
    $notifyHelp.ForeColor = $palette.Muted
    $statusLabel.ForeColor = $palette.Text
    $btnTheme.Text = if ($Name -eq 'night') { '主题：夜间' } else { '主题：白天' }
    try { & $updateToggle } catch { }
    $form.Invalidate($true)
}

$btnTheme.Add_Click({
    if ($script:themeName -eq 'night') { Apply-Theme 'day' } else { Apply-Theme 'night' }
    try {
        $config = Get-AppConfig
        if ($config) {
            $config | Add-Member -NotePropertyName Theme -NotePropertyValue $script:themeName -Force
            Save-AppConfig -Config $config
        }
    } catch { }
    Write-AppLog ('theme switched to ' + $script:themeName)
})

# ---- card look: containers, inputs, tabs -----------------------------------

# ---- reflow page 1 into four headed sections --------------------------------

function Get-AnonLabel {
    param($Parent, [string]$Text)
    return ($Parent.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text -eq $Text } | Select-Object -First 1)
}

$fontHead = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)

$head1 = New-Label -Text '锁屏时段' -X 18 -Y 12 -W 240 -H 26 -Parent $setupBox
$head1.Font = $fontHead
$head2 = New-Label -Text '巡查间隔' -X 18 -Y 116 -W 240 -H 26 -Parent $setupBox
$head2.Font = $fontHead
$head3 = New-Label -Text '应急口令' -X 18 -Y 184 -W 240 -H 26 -Parent $setupBox
$head3.Font = $fontHead
$head4 = New-Label -Text '锁屏图片' -X 18 -Y 286 -W 240 -H 26 -Parent $setupBox
$head4.Font = $fontHead

# section 1: time window
$lblStart.SetBounds(18, 50, 84, 24)
$cmbStartHour.SetBounds(($lblStart.Right + 8), 46, 64, 26)
$lblColon1.SetBounds(($cmbStartHour.Right + 4), 50, 12, 24)
$cmbStartMin.SetBounds(($lblColon1.Right + 4), 46, 64, 26)
$lblEnd.SetBounds(($cmbStartMin.Right + 24), 50, 84, 24)
$cmbEndHour.SetBounds(($lblEnd.Right + 8), 46, 64, 26)
$lblColon2.SetBounds(($cmbEndHour.Right + 4), 50, 12, 24)
$cmbEndMin.SetBounds(($lblColon2.Right + 4), 46, 64, 26)
$previewLabel.SetBounds(18, 82, 500, 26)
$actionBox.Controls.Remove($btnDefaultTime)
$setupBox.Controls.Add($btnDefaultTime)
$btnDefaultTime.SetBounds(540, 80, 150, 30)

# section 2: patrol interval
$lblPatrol.SetBounds(18, 150, 84, 24)
$numPatrol.SetBounds(($lblPatrol.Right + 8), 146, 64, 26)
$hintPatrol = Get-AnonLabel -Parent $setupBox -Text '分钟检查一次（越小越难绕过）'
if ($hintPatrol) { $hintPatrol.SetBounds(($numPatrol.Right + 12), 150, 340, 24) }

# section 3: emergency password
$chkPassword.SetBounds(18, 220, 150, 26)
$txtPassword.SetBounds(180, 216, 300, 30)
$btnRandom.SetBounds(492, 215, 110, 32)
$hintPwd = Get-AnonLabel -Parent $setupBox -Text '按住 Esc 15 秒可解锁；锁屏时也可以插 U 盘解锁。'
if ($hintPwd) {
    $hintPwd.Text = '按住 Esc 15 秒后输入口令即可解锁；也可以插 U 盘（里面有 NIGHTGUARD-UNLOCK.txt）'
    $hintPwd.Tag = 'muted'
    $hintPwd.SetBounds(18, 254, 660, 24)
}

# section 4: lock image
$lblImage.SetBounds(18, 318, 84, 24)
$txtImage.SetBounds(($lblImage.Right + 8), 314, 470, 30)
$btnBrowse.SetBounds(($txtImage.Right + 12), 313, 110, 32)

# ---- page 1 buttons now live in the same card ------------------------------

$btnEnable.SetBounds(18, 14, 166, 34)
$btnStop.SetBounds(192, 14, 166, 34)
$btnPreview.SetBounds(366, 14, 166, 34)
$btnSave.SetBounds(540, 14, 154, 34)
$lblForce.SetBounds(18, 60, 84, 24)
$numForce.SetBounds(($lblForce.Right + 8), 56, 64, 26)
$lblMinutes.SetBounds(($numForce.Right + 8), 60, 44, 24)
$btnForce.SetBounds(($lblMinutes.Right + 12), 56, 140, 30)
$btnFolder.SetBounds(($btnForce.Right + 8), 56, 150, 30)
$btnLog.SetBounds(($btnFolder.Right + 8), 56, 160, 30)
$noticeLabel.SetBounds(18, 96, 676, 26)

# 「完全卸载」与「停止并解除」功能重复，移除
$actionBox.Controls.Remove($btnRemove)
$actionBox.Controls.Remove($note)
$noteSmall = Get-AnonLabel -Parent $actionBox -Text '修改时段后点“保存设置”，会自动重新登记计划任务。'
if ($noteSmall) { $actionBox.Controls.Remove($noteSmall) }

# ---- second pass: drop what the user asked to remove, tighten the rhythm ----

# 顶部已有「生效时段」，这里不再重复显示；有改动时改用底部提示行提醒
$setupBox.Controls.Remove($previewLabel)

# 「恢复默认时段」和直接在下拉框里选一样，去掉
$handlerless = $btnDefaultTime
$setupBox.Controls.Remove($btnDefaultTime)

# 运行日志不再嵌在面板里（仍可用“记事本打开日志”查看）
$form.Controls.Remove($logGroup)

# 段落标题已经说明了内容，行首不再重复
$setupBox.Controls.Remove($lblPatrol)
$setupBox.Controls.Remove($lblImage)

$head1.SetBounds(18, 12, 88, 26)
$lblStart.SetBounds(18, 50, 84, 24)
$cmbStartHour.SetBounds(($lblStart.Right + 8), 46, 64, 26)
$lblColon1.SetBounds(($cmbStartHour.Right + 4), 50, 12, 24)
$cmbStartMin.SetBounds(($lblColon1.Right + 4), 46, 64, 26)
$lblEnd.SetBounds(($cmbStartMin.Right + 28), 50, 84, 24)
$cmbEndHour.SetBounds(($lblEnd.Right + 8), 46, 64, 26)
$lblColon2.SetBounds(($cmbEndHour.Right + 4), 50, 12, 24)
$cmbEndMin.SetBounds(($lblColon2.Right + 4), 46, 64, 26)

$head2.SetBounds(18, 92, 240, 26)
$numPatrol.SetBounds(18, 126, 64, 26)
if ($hintPatrol) { $hintPatrol.SetBounds(($numPatrol.Right + 12), 130, 340, 24) }

$head3.SetBounds(18, 172, 240, 26)
$chkPassword.SetBounds(18, 208, 150, 26)
$txtPassword.SetBounds(180, 204, 300, 30)
$btnRandom.SetBounds(492, 203, 110, 32)
if ($hintPwd) { $hintPwd.SetBounds(18, 242, 660, 24) }

$head4.SetBounds(18, 284, 240, 26)
$txtImage.SetBounds(18, 318, 560, 30)
$btnBrowse.SetBounds(($txtImage.Right + 12), 317, 110, 32)

$form.ClientSize = New-Object System.Drawing.Size(760, 724)

# ---- third pass: even section rhythm + simplified buttons -------------------

if ($hintPatrol) { $setupBox.Controls.Remove($hintPatrol) }

# four sections, identical 16px gap between a section and the next heading
$head1.SetBounds(18, 12, 240, 26)
$lblStart.SetBounds(18, 44, 84, 24)
$cmbStartHour.SetBounds(($lblStart.Right + 8), 40, 64, 26)
$lblColon1.SetBounds(($cmbStartHour.Right + 4), 44, 12, 24)
$cmbStartMin.SetBounds(($lblColon1.Right + 4), 40, 64, 26)
$lblEnd.SetBounds(($cmbStartMin.Right + 28), 44, 84, 24)
$cmbEndHour.SetBounds(($lblEnd.Right + 8), 40, 64, 26)
$lblColon2.SetBounds(($cmbEndHour.Right + 4), 44, 12, 24)
$cmbEndMin.SetBounds(($lblColon2.Right + 4), 40, 64, 26)

$head2.SetBounds(18, 90, 240, 26)
$numPatrol.SetBounds(18, 122, 64, 26)
$lblPatrolUnit = New-Label -Text '分钟检查一次' -X ($numPatrol.Right + 12) -Y 126 -W 140 -H 24 -Parent $setupBox

$head3.SetBounds(18, 168, 240, 26)
$chkPassword.SetBounds(18, 202, 150, 26)
$txtPassword.SetBounds(180, 198, 300, 30)
$btnRandom.SetBounds(492, 197, 110, 32)

$head4.SetBounds(18, 246, 240, 26)
$txtImage.SetBounds(18, 278, 560, 30)
$btnBrowse.SetBounds(($txtImage.Right + 12), 277, 110, 32)

# the unlock hint becomes a footnote so the four sections stay evenly spaced
if ($hintPwd) { $hintPwd.SetBounds(18, 326, 676, 48) }

if ($hintPwd) {
    $hintPwd.Text = '按住 Esc 15 秒输入口令即可解锁，也可以插 U 盘（里面有 NIGHTGUARD-UNLOCK.txt）'
    $hintPwd.SetBounds(18, 330, 676, 24)
}
$setupBox.SetBounds(4, 8, 712, 364)
$actionBox.SetBounds(4, 380, 712, 126)

# buttons: one toggle, shorter labels
$actionBox.Controls.Remove($btnStop)
$btnEnable.SetBounds(18, 14, 190, 36)
$btnPreview.SetBounds(444, 14, 130, 36)
$btnSave.SetBounds(582, 14, 130, 36)
$btnPreview.Text = '预览'
$btnSave.Text = '保存'

$lblForce.SetBounds(18, 66, 0, 0)
$actionBox.Controls.Remove($lblForce)
$numForce.SetBounds(18, 62, 64, 28)
$lblMinutes.SetBounds(90, 66, 44, 24)
$btnForce.SetBounds(142, 62, 140, 32)
$btnForce.Text = '立即锁定'
$btnFolder.SetBounds(300, 62, 150, 32)
$btnFolder.Text = '打开文件夹'
$btnLog.SetBounds(466, 62, 140, 32)
$btnLog.Text = '打开日志'
$noticeLabel.SetBounds(18, 100, 676, 26)

$updateToggle = {
    $btnEnable.BackColor = $palette.Card
    if (Test-Installed) {
        $btnEnable.Text = '停用'
        $btnEnable.Fill = [System.Drawing.Color]::FromArgb(214, 60, 60)
        $btnEnable.HoverFill = [System.Drawing.Color]::FromArgb(190, 45, 45)
        $btnEnable.BorderColor = [System.Drawing.Color]::FromArgb(214, 60, 60)
    } else {
        $btnEnable.Text = '启动'
        $btnEnable.Fill = [System.Drawing.Color]::FromArgb(22, 163, 74)
        $btnEnable.HoverFill = [System.Drawing.Color]::FromArgb(18, 140, 64)
        $btnEnable.BorderColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
    }
    $btnEnable.TextColor = [System.Drawing.Color]::White
    $btnEnable.Tag = ''
    $btnEnable.Invalidate()
}
& $updateToggle

# ---- fourth pass: hint under 应急口令, help marks, even rhythm --------------

if ($hintPwd) {
    $hintPwd.SetBounds(18, 230, 676, 24)
}

$head1.SetBounds(18, 12, 88, 26)
$lblStart.SetBounds(18, 40, 84, 24)
$cmbStartHour.SetBounds(($lblStart.Right + 8), 36, 64, 26)
$lblColon1.SetBounds(($cmbStartHour.Right + 4), 40, 12, 24)
$cmbStartMin.SetBounds(($lblColon1.Right + 4), 36, 64, 26)
$lblEnd.SetBounds(($cmbStartMin.Right + 28), 40, 84, 24)
$cmbEndHour.SetBounds(($lblEnd.Right + 8), 36, 64, 26)
$lblColon2.SetBounds(($cmbEndHour.Right + 4), 40, 12, 24)
$cmbEndMin.SetBounds(($lblColon2.Right + 4), 36, 64, 26)

$head2.SetBounds(18, 86, 88, 26)
$numPatrol.SetBounds(18, 118, 64, 26)
$lblPatrolUnit.SetBounds(($numPatrol.Right + 12), 122, 160, 24)

$head3.SetBounds(18, 160, 88, 26)
$chkPassword.SetBounds(18, 194, 150, 26)
$txtPassword.SetBounds(180, 190, 300, 30)
$btnRandom.SetBounds(492, 189, 110, 32)

$head4.SetBounds(18, 270, 88, 26)
$txtImage.SetBounds(18, 302, 560, 30)
$btnBrowse.SetBounds(590, 301, 110, 32)

$setupBox.SetBounds(4, 8, 712, 352)
$actionBox.SetBounds(4, 368, 712, 126)

# small "?" next to every section heading; click it to read the explanation
$helpTexts = [ordered]@{
    '锁屏时段' = '每天这个时间段内电脑会锁定，可以跨天（例如 23:00 到 06:00）。到点自动锁，到点自动解除。'
    '巡查间隔' = '每隔这么久检查一次锁定状态：该锁却没锁会立刻补上，不在时段内发现残留限制会主动清理。数值越小越难绕过。'
    '应急口令' = '锁屏时按住 Esc 15 秒，输入这串口令就能解锁。口令只有你自己知道，锁屏时查不到，所以必须把口令推送到手机，或者随身带一个 U 盘钥匙文件。'
    '锁屏图片' = '锁屏时全屏显示的图片。建议用 1920×1080 或同比例；深色底 + 浅色大字在夜里最醒目，也不刺眼。'
}

function New-HelpMark {
    param([string]$Key, [int]$X, [int]$Y, $Parent)
    $m = New-Object System.Windows.Forms.Label
    $m.Text = '?'
    $m.AutoSize = $false
    $m.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $m.SetBounds($X, $Y, 22, 22)
    $m.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $m.ForeColor = $palette.Accent
    $m.BackColor = [System.Drawing.Color]::Transparent
    $m.Cursor = [System.Windows.Forms.Cursors]::Hand
    $m.Tag = 'link'
    $m.AccessibleDescription = [string]$helpTexts[$Key]
    $m.Add_Click({ param($sender, $e) Set-Notice ([string]$sender.AccessibleDescription) })
    $Parent.Controls.Add($m)
    return $m
}

[void](New-HelpMark -Key '锁屏时段' -X 108 -Y 14 -Parent $setupBox)
[void](New-HelpMark -Key '巡查间隔' -X 108 -Y 88 -Parent $setupBox)
[void](New-HelpMark -Key '应急口令' -X 108 -Y 162 -Parent $setupBox)
[void](New-HelpMark -Key '锁屏图片' -X 108 -Y 272 -Parent $setupBox)

# ---- sixth pass: two tidy button rows ---------------------------------------

$actionBox.Controls.Remove($numForce)
$lblMinutes.Visible = $false
$actionBox.Controls.Remove($lblMinutes)

$cmbForceHour = New-Combo -X 338 -Y 16 -Values (0..23) -Parent $actionBox
$lblForceColon = New-Label -Text ':' -X 402 -Y 18 -W 10 -H 24 -Parent $actionBox
$cmbForceMin = New-Combo -X ($lblForceColon.Right + 4) -Y 16 -Values (0..59) -Parent $actionBox
$cmbForceHour.SelectedItem = '00'
$cmbForceMin.SelectedItem = '30'
    $cmbForceHour.Tag = 'input'
    $cmbForceMin.Tag = 'input'

$chkRotate = New-Object System.Windows.Forms.CheckBox
$chkRotate.Text = '每次轮换'
$chkRotate.SetBounds(606, 200, 100, 26)
$chkRotate.ForeColor = $palette.Text
$chkRotate.Tag = 'text'
$setupBox.Controls.Add($chkRotate)

$btnEnable.SetBounds(18, 12, 132, 36)
$btnForce.SetBounds(158, 12, 128, 36)
$cmbForceHour.SetBounds(294, 16, 52, 28)
$lblForceHour = New-Label -Text '小时' -X 350 -Y 18 -W 40 -H 24 -Parent $actionBox
$lblForceColon.SetBounds(($lblForceHour.Right + 2), 18, 10, 24)
$cmbForceMin.SetBounds(($lblForceColon.Right + 4), 16, 52, 28)
$lblForceMin = New-Label -Text '分钟' -X ($cmbForceMin.Right + 6) -Y 18 -W 40 -H 24 -Parent $actionBox
$btnSave.SetBounds(560, 12, 134, 36)
$btnPreview.SetBounds(18, 58, 140, 32)
$btnFolder.SetBounds(170, 58, 150, 32)
$btnLog.SetBounds(332, 58, 150, 32)
$noticeLabel.SetBounds(18, 100, 676, 26)

$setupBox.SetBounds(4, 8, 712, 358)
$actionBox.SetBounds(4, 374, 712, 132)

# ---- seventh pass: patrol interval uses the same hour/minute pickers --------

$setupBox.Controls.Remove($numPatrol)
$cmbPatrolHour = New-Combo -X 18 -Y 118 -Values (0..23) -Parent $setupBox
$lblPatrolHourUnit = New-Label -Text '小时' -X ($cmbPatrolHour.Right + 6) -Y 120 -W 44 -H 24 -Parent $setupBox
$lblPatrolColon = New-Label -Text ':' -X ($lblPatrolHourUnit.Right + 2) -Y 120 -W 10 -H 24 -Parent $setupBox
$cmbPatrolMin = New-Combo -X ($lblPatrolColon.Right + 4) -Y 118 -Values (0..59) -Parent $setupBox
$lblPatrolMinUnit = New-Label -Text '分钟' -X ($cmbPatrolMin.Right + 6) -Y 120 -W 44 -H 24 -Parent $setupBox
$lblPatrolUnit.Text = '检查一次'
$lblPatrolUnit.SetBounds(($lblPatrolMinUnit.Right + 10), 122, 160, 24)
$cmbPatrolHour.SelectedItem = '00'
$cmbPatrolMin.SelectedItem = '01'
$cmbPatrolHour.Tag = 'input'
$cmbPatrolMin.Tag = 'input'
foreach ($c in @($cmbPatrolHour, $cmbPatrolMin)) {
    $setupBox.Fields.Add((New-Object System.Drawing.Rectangle(
        [int]($c.Left - 9), [int]($c.Top - 5), [int]($c.Width + 18), [int]($c.Height + 10))))
}

# ---- fifth pass: notification page shows one channel at a time --------------

$channelDesc = @{
    none     = '不推送通知：锁屏照常工作，只是不会给你发消息。请注意，这样锁屏时你查不到应急口令，只能靠口令或 U 盘。'
    dingtalk = '钉钉群机器人：在钉钉群里点“群设置 → 智能群助手 → 添加机器人 → 自定义”，复制 Webhook 地址；安全设置建议选“加签”，再把密钥一起填进来。'
    wecom    = '企业微信群机器人：在群里点右上角 → 添加群机器人 → 新创建，复制它的 Webhook 地址填到下面。'
    feishu   = '飞书群机器人：群设置 → 群机器人 → 添加机器人 → 自定义机器人，复制 Webhook 地址填到下面。'
    qqmail   = 'QQ 邮箱：在网页版邮箱的“设置 → 账户”里开启 IMAP/SMTP 服务，短信验证后会得到一串 16 位授权码。授权码不是 QQ 密码，请填在下面。'
}

$descLabel = New-Object System.Windows.Forms.Label
$descLabel.AutoSize = $false
$descLabel.ForeColor = $palette.Muted
$descLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$descLabel.Tag = 'muted'
$descLabel.SetBounds(12, 46, 676, 42)
$pageNotify.Controls.Add($descLabel)

function New-Pane {
    param($Parent)
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds(12, 92, 676, 236)
    $p.BackColor = [System.Drawing.Color]::Transparent
    $p.Visible = $false
    $p.Tag = 'pane'
    $Parent.Controls.Add($p)
    return $p
}

function New-Note {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Parent)
    $n = New-Object System.Windows.Forms.Label
    $n.Text = $Text
    $n.AutoSize = $false
    $n.ForeColor = $palette.Muted
    $n.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $n.Tag = 'muted'
    $n.SetBounds($X, $Y, $W, $H)
    $Parent.Controls.Add($n)
    return $n
}

$paneDing   = New-Pane -Parent $pageNotify
$paneWecom  = New-Pane -Parent $pageNotify
$paneFeishu = New-Pane -Parent $pageNotify
$paneMail   = New-Pane -Parent $pageNotify
$paneNone   = New-Pane -Parent $pageNotify

foreach ($pane in @($paneDing, $paneWecom, $paneFeishu)) {
    [void](New-Note -Text '机器人地址' -X 0 -Y 6 -W 110 -H 26 -Parent $pane)
    [void](New-Note -Text '把机器人 Webhook 地址整条粘贴到这里，以 https:// 开头。' -X 0 -Y 44 -W 676 -H 24 -Parent $pane)
}
[void](New-Note -Text '加签密钥' -X 0 -Y 74 -W 110 -H 26 -Parent $paneDing)
[void](New-Note -Text '只有钉钉选了“加签”安全设置才需要填；没开加签就留空。' -X 0 -Y 112 -W 676 -H 24 -Parent $paneDing)

[void](New-Note -Text '发件邮箱' -X 0 -Y 6 -W 110 -H 26 -Parent $paneMail)
[void](New-Note -Text '填你的 QQ 邮箱地址，例如 123456@qq.com（只作为发件人）。' -X 0 -Y 44 -W 676 -H 24 -Parent $paneMail)
[void](New-Note -Text '授权码' -X 0 -Y 78 -W 110 -H 26 -Parent $paneMail)
[void](New-Note -Text '邮箱设置里生成的那 16 位授权码，不是 QQ 密码。' -X 0 -Y 116 -W 676 -H 24 -Parent $paneMail)
[void](New-Note -Text '收件邮箱' -X 0 -Y 150 -W 110 -H 26 -Parent $paneMail)
[void](New-Note -Text '想收到通知的邮箱，填自己同一个 QQ 邮箱也行；多个用逗号隔开。' -X 0 -Y 188 -W 676 -H 24 -Parent $paneMail)

[void](New-Note -Text '当前不推送任何通知。锁定会照常生效，解锁只能靠：按住 Esc 输入口令、插 U 盘、等待解锁，或等时段结束。' -X 0 -Y 20 -W 676 -H 48 -Parent $paneNone)

$applyChannelPane = {
    $key = 'none'
    if ($cmbChannel.SelectedIndex -ge 0) { $key = $channelKeys[[int]$cmbChannel.SelectedIndex] }
    foreach ($p in @($paneDing, $paneWecom, $paneFeishu, $paneMail, $paneNone)) { $p.Visible = $false }

    $target = $paneNone
    if ($key -eq 'dingtalk') { $target = $paneDing }
    elseif ($key -eq 'wecom') { $target = $paneWecom }
    elseif ($key -eq 'feishu') { $target = $paneFeishu }
    elseif ($key -eq 'qqmail') { $target = $paneMail }

    $webhookPanes = @($paneDing, $paneWecom, $paneFeishu)
    if ($webhookPanes -contains $target) {
        if ($txtWebhook.Parent) { $txtWebhook.Parent.Controls.Remove($txtWebhook) }
        $target.Controls.Add($txtWebhook)
        $txtWebhook.SetBounds(118, 2, 540, 30)
    } else {
        if ($txtWebhook.Parent) { $txtWebhook.Parent.Controls.Remove($txtWebhook) }
    }

    if ($key -eq 'dingtalk') {
        if ($txtSecret.Parent) { $txtSecret.Parent.Controls.Remove($txtSecret) }
        $target.Controls.Add($txtSecret)
        $txtSecret.SetBounds(118, 74, 380, 30)
    } else {
        if ($txtSecret.Parent) { $txtSecret.Parent.Controls.Remove($txtSecret) }
    }

    foreach ($c in @($txtMailFrom, $txtAuthCode, $txtMailTo)) {
        if ($c.Parent) { $c.Parent.Controls.Remove($c) }
    }
    if ($key -eq 'qqmail') {
        $target.Controls.Add($txtMailFrom)
        $txtMailFrom.SetBounds(118, 2, 320, 30)
        $target.Controls.Add($txtAuthCode)
        $txtAuthCode.SetBounds(118, 74, 320, 30)
        $target.Controls.Add($txtMailTo)
        $txtMailTo.SetBounds(118, 146, 420, 30)
    }

    $descLabel.Text = [string]$channelDesc[$key]
    $target.Visible = $true
}

$cmbChannel.Add_SelectedIndexChanged({ & $applyChannelPane })

# clean up the old flat layout of this page and move the shared rows below the panes
foreach ($old in @('机器人地址', '加签密钥', '发件邮箱', '授权码', '收件邮箱',
                   '多个收件人用逗号分隔', '只有钉钉的加签模式需要填', '填好参数后先测试一次')) {
    $lbl = Get-AnonLabel -Parent $pageNotify -Text $old
    if ($lbl) { $pageNotify.Controls.Remove($lbl) }
}

$lblTiming = Get-AnonLabel -Parent $pageNotify -Text '推送时机'
if ($lblTiming) { $lblTiming.SetBounds(12, 344, 110, 24) }
$lblBefore = Get-AnonLabel -Parent $pageNotify -Text '锁屏前'
if ($lblBefore) { $pageNotify.Controls.Remove($lblBefore) }
$pageNotify.Controls.Remove($numBefore)
$lblBeforeUnit = Get-AnonLabel -Parent $pageNotify -Text '分钟推送口令'
if ($lblBeforeUnit) { $pageNotify.Controls.Remove($lblBeforeUnit) }
$chkOnLock.SetBounds(130, 342, 400, 26)

$lblWait = Get-AnonLabel -Parent $pageNotify -Text '等待解锁'
if ($lblWait) { $pageNotify.Controls.Remove($lblWait) }
$pageNotify.Controls.Remove($numWait)
$lblWaitHint = Get-AnonLabel -Parent $pageNotify -Text '分钟后锁屏界面上出现“可解锁”按钮，0 = 关闭'
if ($lblWaitHint) { $pageNotify.Controls.Remove($lblWaitHint) }
$numWait.Value = 0

$notifyHelp.SetBounds(12, 420, 676, 84)
$notifyHelp.Text = '提醒：通知是锁屏的附加功能——要先在「锁屏设置」里点「启动」，通知才会真正生效。'
$notifyHelp.SetBounds(12, 420, 676, 48)

$tabs.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10)

foreach ($page in @($pageLock, $pageNotify)) {
    $page.UseVisualStyleBackColor = $false
    $page.BackColor = $palette.Card
}

foreach ($box in @($statusBox, $setupBox, $actionBox, $logGroup)) {
    $box.BackColor = $palette.Bg
    $box.Tag = 'card'
}

$statusLabel.ForeColor = $palette.Text
$statusLabel.Tag = 'text'
$previewLabel.Tag = ''
$note.Tag = 'muted'
$notifyHelp.Tag = 'muted'

foreach ($input in @($txtPassword, $txtImage, $txtWebhook, $txtSecret, $txtMailFrom, $txtAuthCode, $txtMailTo,
                     $numPatrol, $numForce, $numBefore, $numWait,
                     $cmbStartHour, $cmbStartMin, $cmbEndHour, $cmbEndMin, $cmbChannel)) {
    $input.Tag = 'input'
}

# rounded backdrop behind every input control, drawn by the parent card
function Add-FieldBackdrop {
    param($Card, $Inputs)
    foreach ($c in @($Inputs)) {
        if (-not $c) { continue }
        $rect = New-Object System.Drawing.Rectangle(
            [int]($c.Left - 9), [int]($c.Top - 5),
            [int]($c.Width + 18), [int]($c.Height + 10))
        $Card.Fields.Add($rect)
    }
    $Card.Invalidate()
}

Add-FieldBackdrop -Card $setupBox -Inputs @($cmbStartHour, $cmbStartMin, $cmbEndHour, $cmbEndMin, $numPatrol, $txtPassword, $txtImage)

foreach ($input in @($txtPassword, $txtImage, $txtWebhook, $txtSecret, $txtMailFrom, $txtAuthCode, $txtMailTo)) {
    $input.BackColor = $palette.Card
    $input.ForeColor = $palette.Text
    $input.BorderStyle = 'FixedSingle'
}

foreach ($spin in @($numPatrol, $numForce, $numBefore, $numWait)) {
    $spin.BackColor = $palette.Card
    $spin.ForeColor = $palette.Text
}

$chkPassword.ForeColor = $palette.Text
$chkOnLock.ForeColor = $palette.Text
$note.ForeColor = $palette.Muted
$notifyHelp.ForeColor = $palette.Muted
$logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 253)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)

function Resize-Control {
    param($Control, [double]$Factor)
    if ($Control.Parent) {
        $Control.SetBounds(
            [int][math]::Round($Control.Left * $Factor),
            [int][math]::Round($Control.Top * $Factor),
            [int][math]::Round($Control.Width * $Factor),
            [int][math]::Round($Control.Height * $Factor))
    }
    if ($Control.Font) {
        try {
            $Control.Font = New-Object System.Drawing.Font($Control.Font.FontFamily, [single]($Control.Font.SizeInPoints * $Factor), $Control.Font.Style)
        } catch { }
    }
    foreach ($child in $Control.Controls) { Resize-Control -Control $child -Factor $Factor }
}

$work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$fit = [math]::Min(($work.Width - 30) / $form.ClientSize.Width, ($work.Height - 40) / $form.ClientSize.Height)
if ($fit -lt 1.0) {
    $fit = [math]::Max($fit, 0.6)
    foreach ($control in $form.Controls) { Resize-Control -Control $control -Factor $fit }
    $form.ClientSize = New-Object System.Drawing.Size(
        [int][math]::Round($form.ClientSize.Width * $fit),
        [int][math]::Round($form.ClientSize.Height * $fit))
}

if ($CheckUI) {
    # realise the tab pages first, otherwise they report a placeholder size
    try {
        $form.CreateControl()
        foreach ($p in @($pageLock, $pageNotify)) {
            $tabs.SelectedTab = $p
            $p.PerformLayout()
        }
        $tabs.SelectedTab = $pageLock
    } catch { }
    $form.PerformLayout()
    $script:problems = 0
    $script:checked = 0
    $script:gfx = $form.CreateGraphics()

    function Check-Tree {
        param($Container)

        foreach ($c in $Container.Controls) {
            $b = $c.Bounds
            if ($c.Text -and $c.Text.Trim().Length -gt 0 -and -not ($c -is [System.Windows.Forms.GroupBox])) {
                $script:checked++
                $size = if ($c -is [System.Windows.Forms.Label]) {
                    $script:gfx.MeasureString($c.Text, $c.Font, [int][math]::Max($b.Width, 10))
                } else {
                    $script:gfx.MeasureString($c.Text, $c.Font)
                }
                if ($size.Width -gt ($b.Width + 6) -or $size.Height -gt ($b.Height + 4)) {
                    $script:problems++
                    Write-Host ('  文字超出 → ' + $c.GetType().Name + ' [' + ($c.Text -replace "`r`n", ' / ') + ']  位置 ' + $b.X + ',' + $b.Y + ' 尺寸 ' + $b.Width + 'x' + $b.Height + '  需要 ' + [int]$size.Width + 'x' + [int]$size.Height)
                }
            }
            # the control itself must stay inside its parent, otherwise it gets clipped
            $room = $Container.ClientSize
            if ($Container -is [System.Windows.Forms.TabPage]) {
                $room = $tabs.DisplayRectangle.Size
            }
            if ($b.Right -gt ($room.Width + 1) -or $b.Bottom -gt ($room.Height + 1) -or $b.Left -lt -1 -or $b.Top -lt -1) {
                $script:problems++
                Write-Host ('  超出容器 → [' + $c.Text + '] 位置 ' + $b.X + ',' + $b.Y + ' 尺寸 ' + $b.Width + 'x' + $b.Height + '，容器只有 ' + $room.Width + 'x' + $room.Height)
            }
            Check-Tree -Container $c
        }

        $kids = @($Container.Controls)
        for ($i = 0; $i -lt $kids.Count; $i++) {
            for ($j = $i + 1; $j -lt $kids.Count; $j++) {
                $a = $kids[$i]
                $b = $kids[$j]
                if ($a -is [System.Windows.Forms.GroupBox] -or $b -is [System.Windows.Forms.GroupBox]) { continue }
                if ($a -is [System.Windows.Forms.TabPage] -or $b -is [System.Windows.Forms.TabPage]) { continue }
                if ([string]$a.Tag -eq 'pane' -and [string]$b.Tag -eq 'pane') { continue }
                $ra = $a.Bounds
                $rb = $b.Bounds
                $ox = [math]::Min($ra.Right, $rb.Right) - [math]::Max($ra.Left, $rb.Left)
                $oy = [math]::Min($ra.Bottom, $rb.Bottom) - [math]::Max($ra.Top, $rb.Top)
                if ($ox -gt 2 -and $oy -gt 2) {
                    $script:problems++
                    Write-Host ('  控件重叠 → [' + $a.Text + '](' + $ra.X + ',' + $ra.Y + ' ' + $ra.Width + 'x' + $ra.Height + ') 与 [' + $b.Text + '](' + $rb.X + ',' + $rb.Y + ' ' + $rb.Width + 'x' + $rb.Height + ')  重叠 ' + $ox + 'x' + $oy + ' px')
                }
            }
        }
    }

    Write-Host ('form client: ' + $form.ClientSize.Width + 'x' + $form.ClientSize.Height)
    foreach ($chk in @('none', 'dingtalk', 'wecom', 'feishu', 'qqmail')) {
        $cmbChannel.SelectedIndex = [array]::IndexOf($channelKeys, $chk)
        & $applyChannelPane
        $form.PerformLayout()
        Check-Tree -Container $form
    }
    $script:gfx.Dispose()
    Write-Host ('measured controls: ' + $script:checked)
    if ($script:problems -eq 0) {
        Write-Host '检查结果：所有文字都在控件内，同层控件无重叠'
    } else {
        Write-Host ('检查结果：发现 ' + $script:problems + ' 处问题')
    }
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
