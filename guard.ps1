<#
    NightGuard  -  nightly forced lock screen
    Source is ASCII-only on purpose: user-visible text is loaded from config.json (UTF-8).
    Modes:
      lock       show the full screen image and hold it until the window ends
      supervise  make sure the state matches the current time (start / stop the lock)
      restore    force unlock and put every setting back the way it was
      status     print the current state, for diagnostics
#>
[CmdletBinding()]
param(
    [ValidateSet('lock', 'supervise', 'restore', 'status', 'notify')]
    [string]$Mode = 'supervise',

    [int]$TestSeconds = 0,

    [int]$ForcedMinutes = 0,

    [switch]$ForceLock,

    [switch]$DryRunShutdown,

    [ValidateSet('before', 'onlock')]
    [string]$NotifyStage = 'before'
)

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$StatePath  = Join-Path $Root 'state.json'
$LogDir     = Join-Path $Root 'logs'
$LogPath    = Join-Path $LogDir 'guard.log'

$NotifyScript = Join-Path $Root 'notify.ps1'
if (Test-Path -LiteralPath $NotifyScript) { . $NotifyScript }

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    try {
        $line = '{0} [{1}] {2} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $Mode, $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
        # keep the log small: at 100 lines drop the oldest 50
        $all = @(Get-Content -LiteralPath $LogPath -Encoding UTF8)
        if ($all.Count -ge 100) {
            $kept = $all[($all.Count - 50)..($all.Count - 1)]
            Set-Content -LiteralPath $LogPath -Value $kept -Encoding UTF8
        }
    } catch { }
}

function Get-GuardConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Log ('config parse failed: ' + $_.Exception.Message)
        return $null
    }
}

function New-GuardPassword {
    $alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    $chars = $bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] }
    return (-join $chars)
}

function Get-WindowState {
    param($Config, [datetime]$Now)

    $result = [ordered]@{
        InWindow = $false
        EndAt    = $null
        MinutesToEnd = 0
        Reason   = ''
    }

    if ($TestSeconds -gt 0) {
        $result.InWindow = $true
        $result.EndAt = $Now.AddSeconds($TestSeconds)
        $result.MinutesToEnd = [math]::Round($TestSeconds / 60.0, 2)
        $result.Reason = 'test'
        return $result
    }

    if ($ForcedMinutes -gt 0) {
        $result.InWindow = $true
        $result.EndAt = $Now.AddMinutes($ForcedMinutes)
        $result.MinutesToEnd = $ForcedMinutes
        $result.Reason = 'forced'
        return $result
    }

    $start = [datetime]::ParseExact($Config.StartTime, 'HH:mm', $null)
    $end   = [datetime]::ParseExact($Config.EndTime, 'HH:mm', $null)
    $startToday = $Now.Date.Add($start.TimeOfDay)
    $endToday   = $Now.Date.Add($end.TimeOfDay)
    $crossMidnight = ($start -ge $end)

    if (-not $crossMidnight) {
        if ($Now -ge $startToday -and $Now -lt $endToday) {
            $result.InWindow = $true
            $result.EndAt = $endToday
        }
    }
    else {
        if ($Now -lt $endToday) {
            $result.InWindow = $true
            $result.EndAt = $endToday
        }
        elseif ($Now -ge $startToday) {
            $result.InWindow = $true
            $result.EndAt = $endToday.AddDays(1)
        }
    }

    if ($result.InWindow) {
        $result.MinutesToEnd = [math]::Round(($result.EndAt - $Now).TotalMinutes, 2)
        $result.Reason = 'night-window'
    }

    if (-not $result.InWindow -and $ForceLock) {
        $result.InWindow = $true
        $result.EndAt = $Now.Date.AddDays(1) + $end.TimeOfDay
        $result.MinutesToEnd = [math]::Round(($result.EndAt - $Now).TotalMinutes, 2)
        $result.Reason = 'forced-outside-window'
    }

    return $result
}

# ---------------------------------------------------------------- registry ---

$PolicyTargets = @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System';   Name = 'DisableTaskMgr' },
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoWinKeys' },
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoViewContextMenu' }
)

function Save-And-ApplyPolicies {
    if (Test-Path -LiteralPath $StatePath) {
        Write-Log 'policy state already recorded, re-applying values'
        foreach ($t in $PolicyTargets) {
            if (-not (Test-Path $t.Path)) { New-Item -Path $t.Path -Force | Out-Null }
            Set-ItemProperty -Path $t.Path -Name $t.Name -Value 1 -Type DWord
        }
        return
    }

    $saved = [ordered]@{}
    $i = 0
    foreach ($t in $PolicyTargets) {
        $i++
        $had = $false
        $value = $null
        if (Test-Path $t.Path) {
            $item = Get-ItemProperty -Path $t.Path -Name $t.Name -ErrorAction SilentlyContinue
            if ($item -and ($item.PSObject.Properties.Name -contains $t.Name)) {
                $had = $true
                $value = $item.$($t.Name)
            }
        }
        $saved["k$i"] = [ordered]@{ Path = $t.Path; Name = $t.Name; Had = $had; Value = $value }

        if (-not (Test-Path $t.Path)) { New-Item -Path $t.Path -Force | Out-Null }
        Set-ItemProperty -Path $t.Path -Name $t.Name -Value 1 -Type DWord
    }

    ($saved | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatePath -Encoding UTF8
    Write-Log 'recorded original policy values and applied lock policies'
}

function Restore-Policies {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        foreach ($t in $PolicyTargets) {
            Remove-ItemProperty -Path $t.Path -Name $t.Name -ErrorAction SilentlyContinue
        }
        Write-Log 'no state file found, removed lock policies'
        return
    }

    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8
        $saved = $raw | ConvertFrom-Json
        foreach ($prop in $saved.PSObject.Properties) {
            $entry = $prop.Value
            if ($entry.Had) {
                Set-ItemProperty -Path $entry.Path -Name $entry.Name -Value ([int]$entry.Value) -Type DWord
            }
            else {
                Remove-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
            }
        }
        Write-Log 'restored original policy values'
    } catch {
        Write-Log ('restore failed: ' + $_.Exception.Message)
    }

    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------ processes -----

function Get-GuardProcesses {
    param([switch]$AnyMode)
    try {
        $me = $PID
        $marker = '-File "' + (Join-Path $Root 'guard.ps1') + '"'
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop
        return @($procs | Where-Object {
            $_.ProcessId -ne $me -and $_.CommandLine -and $_.CommandLine -like ('*' + $marker + '*') -and
            ($AnyMode -or $_.CommandLine -like '*-Mode lock*')
        })
    } catch {
        return @()
    }
}

function Stop-GuardProcesses {
    $found = @(Get-GuardProcesses -AnyMode)
    foreach ($p in $found) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Log ('killed guard process ' + $p.ProcessId)
        } catch { }
    }
    return $found.Count
}

# ------------------------------------------------------------ usb key -------

function Test-UsbUnlock {
    param($Config)
    if (-not $Config.UsbUnlockFileName) { return $false }
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                  Where-Object { $_.Root -match '^[A-Za-z]:\\$' -and $_.Root.ToUpper() -ne 'C:\' }
        foreach ($d in $drives) {
            $candidate = Join-Path $d.Root $Config.UsbUnlockFileName
            if (Test-Path -LiteralPath $candidate) {
                Write-Log ('usb unlock key found on ' + $d.Root)
                return $true
            }
        }
    } catch { }
    return $false
}

# -------------------------------------------------------------- lock screen -

$script:LockResult = 'unknown'

function Start-LockScreen {
    param($Config, $WindowState)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $imagePath = [string]$Config.ImagePath
    if (-not (Test-Path -LiteralPath $imagePath)) {
        Write-Log ('image missing, refusing to lock: ' + $imagePath)
        $script:LockResult = 'image-missing'
        return
    }

    $hookOk = $false
    if ($Config.EnableKeyboardBlock) {
        try {
            $hookSource = @'
using System;
using System.Runtime.InteropServices;

public class NightGuardKeyboard
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_TAB = 0x09;
    private const int VK_RETURN = 0x0D;
    private const int VK_BACK = 0x08;
    private const int VK_SHIFT = 0x10;
    private const int VK_CAPITAL = 0x14;
    private const int VK_ESCAPE = 0x1B;
    private const int VK_MENU = 0x12;
    private const int VK_CONTROL = 0x11;
    private const int VK_LWIN = 0x5B;
    private const int VK_RWIN = 0x5C;
    private const int VK_F4 = 0x73;
    private const int VK_OEM_MINUS = 0xBD;

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    private static LowLevelKeyboardProc _proc;
    private static IntPtr _hookId = IntPtr.Zero;
    private static DateTime _escDown = DateTime.MinValue;
    private static bool _escLatch = false;

    public static bool Active = false;
    public static bool CaptureMode = false;
    public static string Buffer = "";
    public static string Password = "";
    public static double EscHoldSeconds = 15.0;
    public static bool Granted = false;
    public static bool WrongFlag = false;

    public static double EscHeldSeconds
    {
        get
        {
            if (_escDown == DateTime.MinValue) return 0.0;
            return (DateTime.Now - _escDown).TotalSeconds;
        }
    }

    public static void ResetState()
    {
        CaptureMode = false;
        Buffer = "";
        WrongFlag = false;
        _escDown = DateTime.MinValue;
        _escLatch = false;
    }

    public static void Start()
    {
        if (_hookId != IntPtr.Zero) return;
        _proc = HookCallback;
        _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
    }

    public static void Stop()
    {
        if (_hookId != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookId);
            _hookId = IntPtr.Zero;
        }
        _proc = null;
    }

    private static string Normalize(string text)
    {
        return text.Replace("-", "").ToUpperInvariant();
    }

    private static char MapKey(int vk)
    {
        bool shift = ((GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0) ^ ((GetKeyState(VK_CAPITAL) & 0x0001) != 0);
        if (vk >= 0x41 && vk <= 0x5A)
        {
            char c = (char)('a' + (vk - 0x41));
            return shift ? Char.ToUpper(c) : c;
        }
        if (vk >= 0x30 && vk <= 0x39) return (char)vk;
        if (vk == VK_OEM_MINUS) return '-';
        return '\0';
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (nCode >= 0 && Active)
            {
                bool down = (wParam == (IntPtr)WM_KEYDOWN) || (wParam == (IntPtr)WM_SYSKEYDOWN);
                bool up = (wParam == (IntPtr)WM_KEYUP) || (wParam == (IntPtr)WM_SYSKEYUP);
                int vk = Marshal.ReadInt32(lParam);

                if (vk == VK_ESCAPE)
                {
                    if (down)
                    {
                        if (CaptureMode)
                        {
                            if (!_escLatch)
                            {
                                CaptureMode = false;
                                Buffer = "";
                                WrongFlag = false;
                                _escDown = DateTime.MinValue;
                            }
                        }
                        else if (_escDown == DateTime.MinValue)
                        {
                            _escDown = DateTime.Now;
                        }
                        else if ((DateTime.Now - _escDown).TotalSeconds >= EscHoldSeconds)
                        {
                            CaptureMode = true;
                            Buffer = "";
                            WrongFlag = false;
                            _escDown = DateTime.MinValue;
                            _escLatch = true;
                        }
                    }
                    else if (up)
                    {
                        _escDown = DateTime.MinValue;
                        _escLatch = false;
                    }
                    return (IntPtr)1;
                }

                if (CaptureMode)
                {
                    // let caps lock and num lock through so the user can toggle them
                    if (vk == 0x14 || vk == 0x90) return CallNextHookEx(_hookId, nCode, wParam, lParam);
                    if (down)
                    {
                        if (vk == VK_RETURN)
                        {
                            if (Buffer.Length > 0)
                            {
                                if (Normalize(Buffer) == Normalize(Password)) { Granted = true; CaptureMode = false; }
                                else { WrongFlag = true; Buffer = ""; }
                            }
                        }
                        else if (vk == VK_BACK)
                        {
                            if (Buffer.Length > 0) Buffer = Buffer.Substring(0, Buffer.Length - 1);
                        }
                        else
                        {
                            char c = MapKey(vk);
                            if (c != '\0' && Buffer.Length < 64) Buffer += c;
                        }
                    }
                    return (IntPtr)1;
                }

                if (vk == VK_LWIN || vk == VK_RWIN) return (IntPtr)1;
                if (down && vk == VK_TAB && (GetAsyncKeyState(VK_MENU) & 0x8000) != 0) return (IntPtr)1;
                if (down && vk == VK_F4 && (GetAsyncKeyState(VK_MENU) & 0x8000) != 0) return (IntPtr)1;
                if (down && vk == VK_TAB && (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0) return (IntPtr)1;
            }
        }
        catch { }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int vKey);
}
'@
            Add-Type -TypeDefinition $hookSource -ErrorAction Stop
            [NightGuardKeyboard]::Start()
            [NightGuardKeyboard]::Active = $true
            $hookOk = $true
            Write-Log 'keyboard filter installed'
        } catch {
            Write-Log ('keyboard filter failed, continuing without it: ' + $_.Exception.Message)
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.ShowInTaskbar   = $false
    $form.TopMost         = $true
    $form.KeyPreview      = $true
    $form.BackColor       = [System.Drawing.Color]::Black
    $form.Text            = 'NightGuard'

    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $form.Bounds = New-Object System.Drawing.Rectangle($bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)

    $picture = New-Object System.Windows.Forms.PictureBox
    $picture.Dock     = [System.Windows.Forms.DockStyle]::Fill
    $picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picture.BackColor = [System.Drawing.Color]::Black
    $picture.Image    = [System.Drawing.Image]::FromFile($imagePath)
    $form.Controls.Add($picture)

    $script:AllowClose   = $false
    $script:LockStart    = Get-Date
    $script:MaxEnd       = (Get-Date).AddHours([double]$Config.MaxLockHours)
    $script:LockEndAt    = $WindowState.EndAt
    $script:LastUsbPoll  = Get-Date
    $script:SlideHidden  = $false
    $script:ShutdownMode = ''
    $script:Texts        = $Config.Texts
    $script:HookOk       = $hookOk
    $script:HookHold     = [double]$Config.EscHoldSeconds
    $script:MaskChar     = if ($Config.Texts.MaskChar) { [string]$Config.Texts.MaskChar } else { '*' }

    $script:PasswordEnabled = $true
    if ($Config.PSObject.Properties.Name -contains 'EnablePassword') {
        $script:PasswordEnabled = [bool]$Config.EnablePassword
    }

    if ($hookOk) {
        [NightGuardKeyboard]::Password = [string]$Config.UnlockPassword
        if ($script:PasswordEnabled) {
            [NightGuardKeyboard]::EscHoldSeconds = [double]$Config.EscHoldSeconds
        }
        else {
            [NightGuardKeyboard]::EscHoldSeconds = 1000000.0
        }
    }

    # ---- status hint at the bottom, only visible while unlocking ----
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text      = ''
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(255, 208, 220, 245)
    $hint.BackColor = [System.Drawing.Color]::FromArgb(255, 10, 14, 26)
    $hint.Font      = New-Object System.Drawing.Font('Microsoft YaHei', 20, [System.Drawing.FontStyle]::Regular)
    $hint.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $hint.SetBounds(0, ($form.ClientSize.Height - 132), $form.ClientSize.Width, 64)
    $hint.Visible = $false
    $form.Controls.Add($hint)
    $hint.BringToFront()

    # ---- power buttons: shutting down does not weaken the lock at all ----
    $btnStyle = @{
        FlatStyle = 'Flat'
        Size      = (New-Object System.Drawing.Size(132, 42))
        Font      = (New-Object System.Drawing.Font('Microsoft YaHei', 12))
        BackColor = [System.Drawing.Color]::FromArgb(255, 22, 28, 44)
        ForeColor = [System.Drawing.Color]::FromArgb(255, 225, 232, 245)
    }

    $btnShutdown = New-Object System.Windows.Forms.Button
    $btnShutdown.Text = [string]$Config.Texts.PowerOff
    $btnShutdown.FlatStyle    = $btnStyle.FlatStyle
    $btnShutdown.Size         = $btnStyle.Size
    $btnShutdown.Font         = $btnStyle.Font
    $btnShutdown.BackColor    = $btnStyle.BackColor
    $btnShutdown.ForeColor    = $btnStyle.ForeColor
    $btnShutdown.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(255, 88, 102, 132)
    $btnShutdown.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 320), ($form.ClientSize.Height - 74))

    $btnRestart = New-Object System.Windows.Forms.Button
    $btnRestart.Text = [string]$Config.Texts.Reboot
    $btnRestart.FlatStyle    = $btnStyle.FlatStyle
    $btnRestart.Size         = $btnStyle.Size
    $btnRestart.Font         = $btnStyle.Font
    $btnRestart.BackColor    = $btnStyle.BackColor
    $btnRestart.ForeColor    = $btnStyle.ForeColor
    $btnRestart.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(255, 88, 102, 132)
    $btnRestart.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 168), ($form.ClientSize.Height - 74))

    $form.Controls.Add($btnShutdown)
    $form.Controls.Add($btnRestart)
    $btnShutdown.BringToFront()
    $btnRestart.BringToFront()
    $btnShutdown.TabStop = $false
    $btnRestart.TabStop  = $false
    $form.ActiveControl  = $null
    Write-Log ('power buttons ready: shutdown=' + $btnShutdown.Bounds + ' restart=' + $btnRestart.Bounds)

    $btnShutdown.Add_Click({
        Write-Log 'shutdown button clicked'
        $script:ShutdownMode = 'shutdown'
        $script:LockResult   = 'power-off'
        $script:AllowClose   = $true
        $form.Close()
    })
    $btnRestart.Add_Click({
        Write-Log 'restart button clicked'
        $script:ShutdownMode = 'restart'
        $script:LockResult   = 'restart'
        $script:AllowClose   = $true
        $form.Close()
    })

    # ---- optional "wait then unlock" escape ----
    # ---- caption under the picture ----
    $info = New-Object System.Windows.Forms.Label
    $info.Text = ''
    $info.Font = New-Object System.Drawing.Font('Microsoft YaHei', 16)
    $info.ForeColor = [System.Drawing.Color]::FromArgb(255, 198, 212, 238)
    $info.BackColor = [System.Drawing.Color]::FromArgb(205, 8, 12, 22)
    $info.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $info.SetBounds(0, ($form.ClientSize.Height - 208), $form.ClientSize.Width, 46)
    $form.Controls.Add($info)
    $info.BringToFront()

    $script:InfoIsForced = ($WindowState.Reason -eq 'forced' -or $WindowState.Reason -eq 'test')
    $script:InfoTotalMinutes = 0.0
    if ($script:InfoIsForced) {
        if ($TestSeconds -gt 0) { $script:InfoTotalMinutes = ([double]$TestSeconds / 60.0) }
        elseif ($ForcedMinutes -gt 0) { $script:InfoTotalMinutes = [double]$ForcedMinutes }
        else { $script:InfoTotalMinutes = [math]::Round(($WindowState.EndAt - (Get-Date)).TotalMinutes, 1) }
    }

    $formatDuration = {
        param([double]$Minutes)
        $m = [int][math]::Ceiling($Minutes)
        if ($m -ge 60) { return (([string]$Config.Texts.DurationHM) -f [int]($m / 60), ($m % 60)) }
        return (([string]$Config.Texts.DurationM) -f $m)
    }

    if (-not $script:InfoIsForced) {
        $info.Text = (([string]$Config.Texts.InfoNight) -f $Config.StartTime, $Config.EndTime)
    }

    $script:WaitUnlockMinutes = 0
    $btnWait = $null
    if ($Config.PSObject.Properties.Name -contains 'WaitUnlockMinutes') {
        $script:WaitUnlockMinutes = [int]$Config.WaitUnlockMinutes
    }
    if ($script:WaitUnlockMinutes -gt 0) {
        $btnWait = New-Object System.Windows.Forms.Button
        $btnWait.FlatStyle = 'Flat'
        $btnWait.Size = New-Object System.Drawing.Size(320, 42)
        $btnWait.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
        $btnWait.BackColor = [System.Drawing.Color]::FromArgb(255, 22, 28, 44)
        $btnWait.ForeColor = [System.Drawing.Color]::FromArgb(255, 180, 195, 225)
        $btnWait.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(255, 88, 102, 132)
        $btnWait.Location = New-Object System.Drawing.Point(20, ($form.ClientSize.Height - 74))
        $btnWait.Enabled = $false
        $btnWait.Visible = $false
        $btnWait.Text = '...'
        $btnWait.Add_Click({
            $script:LockResult = 'wait-unlock'
            $script:AllowClose = $true
            $form.Close()
        })
        $form.Controls.Add($btnWait)
        $btnWait.BringToFront()
        Write-Log ('wait unlock offered after ' + $script:WaitUnlockMinutes + ' minutes')
    }

    $form.Add_FormClosing({
        param($sender, $e)
        $systemClose = ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) -or
                       ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::TaskManagerClosing) -or
                       ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::ApplicationExitCall)
        if (-not $systemClose -and -not $script:AllowClose) { $e.Cancel = $true }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        $now = Get-Date

        if ($now -ge $script:LockEndAt) {
            $script:LockResult = 'window-ended'
            $script:AllowClose = $true
            $form.Close()
            return
        }

        if ($now -ge $script:MaxEnd) {
            $script:LockResult = 'max-duration'
            $script:AllowClose = $true
            $form.Close()
            return
        }

        if (((Get-Date) - $script:LastUsbPoll).TotalSeconds -ge 3) {
            $script:LastUsbPoll = Get-Date
            if (Test-UsbUnlock -Config $script:Config) {
                $script:LockResult = 'usb-key'
                $script:AllowClose = $true
                $form.Close()
                return
            }
        }

        # emergency unlock, captured by the global keyboard hook (no focus needed)
        if ($script:HookOk) {
            $capturing = [NightGuardKeyboard]::CaptureMode
            if ($capturing -and -not $script:WasCapturing) { Write-Log 'emergency prompt opened (esc held)' }
            if (-not $capturing -and $script:WasCapturing) {
                if ([NightGuardKeyboard]::Granted) { Write-Log 'emergency password accepted' }
                else { Write-Log 'emergency prompt left' }
            }
            $script:WasCapturing = $capturing

            if ([NightGuardKeyboard]::EscHeldSeconds -gt 0.1 -and -not $script:WasHolding) {
                Write-Log 'esc hold started'
                $script:WasHolding = $true
            }
            elseif ([NightGuardKeyboard]::EscHeldSeconds -le 0.1 -and $script:WasHolding) {
                $script:WasHolding = $false
            }

            if ([NightGuardKeyboard]::Granted) {
                $script:LockResult = 'password'
                $script:AllowClose = $true
                $form.Close()
                return
            }

            if ($script:PasswordEnabled -and [NightGuardKeyboard]::CaptureMode) {
                if ($script:MaskChar) {
                    $shown = ($script:MaskChar * [NightGuardKeyboard]::Buffer.Length) -join ''
                } else {
                    $shown = [string][NightGuardKeyboard]::Buffer
                }
                $line = [string]$script:Texts.UnlockTyping + '   ' + $shown
                if ([NightGuardKeyboard]::WrongFlag) { $line = [string]$script:Texts.UnlockWrong }
                $hint.Text    = $line
                $hint.Visible = $true
            }
            elseif ($script:PasswordEnabled -and [NightGuardKeyboard]::EscHeldSeconds -ge 2) {
                $remain = [int][math]::Ceiling($script:HookHold - [NightGuardKeyboard]::EscHeldSeconds)
                if ($remain -lt 1) { $remain = 1 }
                $hint.Text    = ([string]$script:Texts.UnlockHold -f $remain)
                $hint.Visible = $true
            }
            else {
                $hint.Visible = $false
            }
        }

        # step aside for the built-in slide-to-shut-down screen
        $slideUp = $false
        try {
            $slideUp = [bool](Get-Process -Name 'SlideToShutDown' -ErrorAction SilentlyContinue)
        } catch { }

        if ($slideUp -and -not $script:SlideHidden) {
            $script:SlideHidden = $true
            $form.Visible = $false
            Write-Log 'slide to shut down detected, moving aside'
        }
        elseif (-not $slideUp -and $script:SlideHidden) {
            $script:SlideHidden = $false
            $form.Visible = $true
            $form.TopMost = $true
            Write-Log 'slide to shut down closed, resuming'
        }

        if (-not $script:SlideHidden -and -not $form.TopMost) { $form.TopMost = $true }

        if ($script:WaitUnlockMinutes -gt 0 -and $btnWait) {
            $elapsedMin = ((Get-Date) - $script:LockStart).TotalMinutes
            if ($elapsedMin -ge $script:WaitUnlockMinutes) {
                if (-not $btnWait.Enabled) {
                    $btnWait.Text = [string]$script:Texts.WaitReady
                    $btnWait.ForeColor = [System.Drawing.Color]::FromArgb(255, 150, 230, 170)
                    $btnWait.Enabled = $true
                    $btnWait.Visible = $true
                    Write-Log 'wait unlock is now available'
                }
            }
        }

        if ($script:InfoIsForced) {
            $left = ($script:LockEndAt - (Get-Date)).TotalMinutes
            if ($left -lt 0) { $left = 0 }
            $info.Text = (([string]$Config.Texts.InfoForced) -f (& $formatDuration $script:InfoTotalMinutes), (& $formatDuration $left))
        }
    })

    $script:Config = $Config
    $timer.Start()

    Write-Log ('lock screen shown until ' + $script:LockEndAt.ToString('yyyy-MM-dd HH:mm:ss'))
    [System.Windows.Forms.Application]::Run($form)

    $timer.Stop()
    $timer.Dispose()
    if ($hookOk) { try { [NightGuardKeyboard]::Stop() } catch { } }
    if ($picture.Image) { $picture.Image.Dispose() }
    $form.Dispose()
    Write-Log ('lock screen closed, result: ' + $script:LockResult)
}

# ------------------------------------------------------------------ modes ---

function Invoke-Restore {
    $killed = Stop-GuardProcesses
    Restore-Policies
    Write-Log ('restore complete, processes killed: ' + $killed)
}

function Invoke-Supervise {
    param($Config)
    $state = Get-WindowState -Config $Config -Now (Get-Date)

    if (-not $state.InWindow) {
        $running = @(Get-GuardProcesses)
        if ($running.Count -gt 0) {
            Invoke-Restore
        }
        else {
            Restore-Policies
        }
        Write-Log 'outside the lock window, nothing to do'
        return
    }

    $running = @(Get-GuardProcesses)
    if ($running.Count -gt 0) {
        Write-Log ('inside window, lock already running as pid ' + $running[0].ProcessId)
        return
    }

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $Root 'guard.ps1') + '"'), '-Mode', 'lock')
    Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden
    Write-Log 'inside window, lock process started'
}

$config = Get-GuardConfig
if (-not $config) {
    Write-Log 'no usable config, exiting without locking'
    exit 1
}

switch ($Mode) {
    'status' {
        $state = Get-WindowState -Config $config -Now (Get-Date)
        $running = @(Get-GuardProcesses)
        Write-Output ('now          : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Output ('window       : ' + $config.StartTime + ' - ' + $config.EndTime)
        Write-Output ('in window    : ' + $state.InWindow + ' (' + $state.Reason + ')')
        Write-Output ('ends at      : ' + $state.EndAt)
        Write-Output ('lock running : ' + $running.Count)
        Write-Output ('state file   : ' + (Test-Path -LiteralPath $StatePath))
    }
    'restore' {
        Invoke-Restore
    }
    'notify' {
        $n = $config.Notify
        if (-not $n -or -not $n.Enabled) {
            Write-Log 'notify: notification is off, nothing sent'
            exit 0
        }
        $waitMinutes = 0
        if ($config.PSObject.Properties.Name -contains 'WaitUnlockMinutes') {
            $waitMinutes = [int]$config.WaitUnlockMinutes
        }
        $patrol = $config.PatrolMinutes
        if (-not $patrol) { $patrol = 1 }

        $statusLine = ''
        $tail = ''
        if ($NotifyStage -eq 'onlock') {
            $statusLine = [string]$config.Texts.StatusOnLock
            if ($config.Texts.TailOnLock) { $tail = ([string]$config.Texts.TailOnLock) -f $config.EndTime }
        } else {
            $statusLine = ([string]$config.Texts.StatusBefore) -f $n.BeforeMinutes
        }

        $passwordText = [string]$config.Texts.PasswordOff
        if (-not $passwordText) { $passwordText = 'not set' }
        if ($config.EnablePassword) { $passwordText = [string]$config.UnlockPassword }
        $waitText = [string]$config.Texts.WaitOff
        if (-not $waitText) { $waitText = 'off' }
        if ($waitMinutes -gt 0 -and $config.Texts.WaitOn) {
            $waitText = ([string]$config.Texts.WaitOn) -f $waitMinutes
        }
        # when the password rotates at lock time, the "before" mail must not carry a stale one
        if ($config.EnablePassword -and $NotifyStage -eq 'before' -and
            ($config.PSObject.Properties.Name -contains 'RotatePassword') -and $config.RotatePassword) {
            if ($config.Texts.PasswordPending) { $passwordText = [string]$config.Texts.PasswordPending }
        }

        if ($config.Texts.MsgFull) {
            $body = ([string]$config.Texts.MsgFull) -f $statusLine, $config.StartTime, $config.EndTime, $passwordText, $waitText, $patrol, $tail
        } elseif ($config.EnablePassword) {
            if ($NotifyStage -eq 'onlock') {
                $body = ([string]$config.Texts.MsgOnLock) -f $config.UnlockPassword, $config.EndTime
            } else {
                $body = ([string]$config.Texts.MsgBefore) -f $n.BeforeMinutes, $config.UnlockPassword
            }
        } else {
            $body = ([string]$config.Texts.MsgNoPassword) -f $waitMinutes, $config.EndTime
        }
        if (-not $body) { $body = 'NightLock notification' }
        $r = Send-Notify -Notify $n -Subject ([string]$config.Texts.MailSubject) -Body $body
        Write-Log ('notify(' + $NotifyStage + '): ' + $r.Message)
    }
    'supervise' {
        Invoke-Supervise -Config $config
    }
    'lock' {
        $state = Get-WindowState -Config $config -Now (Get-Date)
        if (-not $state.InWindow) {
            Write-Log 'not inside the lock window, refusing to lock'
            exit 0
        }
        # only one lock screen at a time: the one already running wins
        $existing = @(Get-GuardProcesses)
        if ($existing.Count -gt 0) {
            Write-Log ('another lock screen is already running as pid ' + $existing[0].ProcessId + ', not starting a second one')
            exit 0
        }
        try {
            Save-And-ApplyPolicies
        } catch {
            Write-Log ('failed to apply policies: ' + $_.Exception.Message)
        }
        # rotate the emergency password for every lock session when enabled
        if (($config.PSObject.Properties.Name -contains 'RotatePassword') -and $config.RotatePassword -and $config.EnablePassword) {
            try {
                $config.UnlockPassword = New-GuardPassword
                ($config | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
                Write-Log 'emergency password rotated for this session'
            } catch {
                Write-Log ('password rotation failed: ' + $_.Exception.Message)
            }
        }
        if ($config.Notify -and $config.Notify.Enabled -and $config.Notify.OnLock) {
            try {
                $notifyExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                Start-Process -FilePath $notifyExe -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                    '-File', ('"' + (Join-Path $Root 'guard.ps1') + '"'),
                    '-Mode', 'notify', '-NotifyStage', 'onlock'
                ) -WindowStyle Hidden
                Write-Log 'lock notification dispatched'
            } catch {
                Write-Log ('notify dispatch failed: ' + $_.Exception.Message)
            }
        }
        try {
            Start-LockScreen -Config $config -WindowState $state
        } catch {
            Write-Log ('lock screen error: ' + $_.Exception.Message)
        }
        try {
            Restore-Policies
        } catch {
            Write-Log ('policy restore error: ' + $_.Exception.Message)
        }
        if ($script:ShutdownMode) {
            $verb = if ($script:ShutdownMode -eq 'restart') { '/r' } else { '/s' }
            $exe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
            if ($DryRunShutdown) {
                Write-Log ('dry run, would execute: ' + $exe + ' ' + $verb + ' /t 0')
            }
            else {
                Write-Log ('executing: ' + $exe + ' ' + $verb + ' /t 0')
                Start-Process -FilePath $exe -ArgumentList @($verb, '/t', '0') -WindowStyle Hidden
            }
        }
        Write-Log 'lock mode finished'
    }
}
