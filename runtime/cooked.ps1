# cooked.ps1: the one entry point the /cooked skill calls. Windows PowerShell 5.1, per user, no admin.
#   cooked.ps1 check                              preflight; prints JSON
#   cooked.ps1 install [-Voice <name in voices/>|<file.json>] [-Sound default|none|<file>] [-MinSeconds N]
#                                                 builds and registers everything under ~/.claude/cooked;
#                                                 prints the hook commands to put in settings.json
#   cooked.ps1 test                               fires a real toast, skipping the quiet rules
#   cooked.ps1 validate -Voice <name>|<file.json> checks a voice file
#   cooked.ps1 uninstall                          removes the app id, click handler, toasts and ~/.claude/cooked
param(
    [Parameter(Position = 0)][ValidateSet('check', 'install', 'test', 'validate', 'uninstall')][string]$Action = 'check',
    [string]$Voice,
    [string]$Sound,
    [int]$MinSeconds = -1
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$src       = $PSScriptRoot
$skill     = Split-Path $src -Parent
$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$data      = Join-Path $claudeDir 'cooked'
$settings  = Join-Path $claudeDir 'settings.json'
$appId     = 'Cooked.ClaudeCode'
$appKey    = "HKCU:\Software\Classes\AppUserModelId\$appId"
$protoKey  = 'HKCU:\Software\Classes\cooked'
$soundExt  = '.mp3', '.wav', '.wma'
# Install copies this script, the voices and a README into $data, so it also runs from there
# (change voice, test, uninstall) after the skill folder is gone.
$fromData  = $src.TrimEnd('\') -ieq $data.TrimEnd('\')
$voices    = if ($fromData) { Join-Path $data 'voices' } else { Join-Path $skill 'voices' }

function Out-Json($o) { $o | ConvertTo-Json -Depth 6 }
function Read-Json($p) { Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json }

function Stop-Cooked {
    Get-Process cooked -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($data, [StringComparison]::OrdinalIgnoreCase) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-Csc {
    foreach ($fw in 'Framework64', 'Framework') {
        $c = Join-Path $env:WINDIR "Microsoft.NET\$fw\v4.0.30319\csc.exe"
        if (Test-Path $c) { return $c }
    }
    ''
}

# A bare name ("english") means voices/<name>.json, so a new voice is just a new file there.
function Resolve-Voice($v) {
    $shipped = Join-Path $voices "$v.json"
    if ($v -match '^[\w-]+$' -and (Test-Path $shipped)) { return @{ file = $shipped; name = $v } }
    @{ file = (Resolve-Path $v).Path; name = 'custom' }
}

function Test-Voice($path) {
    $p = @()
    try { $v = Read-Json $path } catch { return , "not valid JSON: $($_.Exception.Message)" }
    foreach ($k in 'done_prefix', 'needs_prefix', 'test_body') { if (-not $v.$k) { $p += "missing $k" } }
    $lists = 'done_titles', 'done_body_fallback', 'permission_titles', 'permission_bodies', 'question_titles', 'question_bodies', 'auth_titles'
    foreach ($k in $lists) { if (-not $v.$k -or @($v.$k).Count -eq 0) { $p += "missing or empty $k" } }
    foreach ($k in 'done_titles', 'permission_titles', 'question_titles', 'auth_titles') {
        foreach ($t in @($v.$k)) {
            if ($t -notmatch '\{session\}') { $p += "$k needs {session}: '$t'" }
            $len = ($t -replace '\{session\}', 'xxxxxxxxxx').Length + 2
            if ($len -gt 40) { $p += "$k over 40 chars with prefix: '$t' ($len)" }
        }
    }
    foreach ($t in @($v.permission_bodies)) { if ($t -notmatch '\{tool\}') { $p += "permission_bodies needs {tool}: '$t'" } }
    , $p
}

function New-Icon($png) {
    Add-Type -AssemblyName System.Drawing
    $s = 256; $r = 64
    $bmp = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r, $r, 180, 90); $path.AddArc($s - $r - 1, 0, $r, $r, 270, 90)
    $path.AddArc($s - $r - 1, $s - $r - 1, $r, $r, 0, 90); $path.AddArc(0, $s - $r - 1, $r, $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(217, 119, 87))), $path)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), 22
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    foreach ($a in 0, 45, 90, 135) {
        $rad = $a * [Math]::PI / 180; $dx = [Math]::Cos($rad) * 70; $dy = [Math]::Sin($rad) * 70
        $g.DrawLine($pen, [float](128 - $dx), [float](128 - $dy), [float](128 + $dx), [float](128 + $dy))
    }
    $bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

function Get-Hooks {
    $notify = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $data 'notify.ps1')`""
    $mark   = "`"$((Join-Path $data 'cooked.exe') -replace '\\', '/')`" --mark"
    [ordered]@{ Stop = $notify; Notification = $notify; UserPromptSubmit = $mark }
}

function Test-HooksInSettings {
    if (-not (Test-Path $settings)) { return $false }
    (Get-Content $settings -Raw -Encoding UTF8) -match 'cooked(\\\\|\\|/)(notify\.ps1|cooked\.exe)'
}

switch ($Action) {

    'check' {
        $toasts = $true
        try { if ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications').ToastEnabled -eq 0) { $toasts = $false } } catch { }
        $os  = [Environment]::OSVersion.Version
        $cfg = if (Test-Path (Join-Path $data 'config.json')) { Read-Json (Join-Path $data 'config.json') } else { $null }
        Out-Json ([ordered]@{
            windows          = "$($os.Major).$($os.Minor).$($os.Build)"
            supported        = ($os.Major -ge 10)
            toasts_enabled   = $toasts
            compiler         = [bool](Get-Csc)
            windows_terminal = [bool]$env:WT_SESSION
            installed        = [bool]$cfg
            current          = if ($cfg) { [ordered]@{ voice = $cfg.voice; sound = $cfg.sound; min_seconds = $cfg.min_seconds } } else { $null }
            hooks_in_settings = Test-HooksInSettings
            settings_path    = $settings
            data_dir         = $data
        })
    }

    'validate' {
        if (-not $Voice) { throw 'validate needs -Voice <name> or <file.json>' }
        $p = Test-Voice (Resolve-Voice $Voice).file
        if ($p.Count) { Out-Json ([ordered]@{ ok = $false; problems = $p }); exit 1 }
        Out-Json ([ordered]@{ ok = $true })
    }

    'install' {
        if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'cooked needs Windows 10 or 11.' }
        if (-not (Get-Csc)) { throw 'The .NET Framework 4 compiler (csc.exe) is missing; it ships with Windows 10/11, so .NET Framework 4.x may be disabled.' }

        # Voice first, so a bad custom file fails before anything changes.
        $voiceName = $null; $voiceFile = $null
        if ($Voice) {
            $r = Resolve-Voice $Voice
            $voiceFile = $r.file; $voiceName = $r.name
            $p = Test-Voice $voiceFile
            if ($p.Count) { Out-Json ([ordered]@{ ok = $false; problems = $p }); exit 1 }
        }
        if ($Sound -and $Sound -notin 'default', 'none') {
            if (-not (Test-Path $Sound)) { throw "Sound file not found: $Sound" }
            if ([IO.Path]::GetExtension($Sound).ToLower() -notin $soundExt) { throw "Sound must be .mp3, .wav or .wma: $Sound" }
        }

        Stop-Cooked
        New-Item -ItemType Directory -Force $data, (Join-Path $data '.state'), (Join-Path $data 'voices') | Out-Null
        if (-not $fromData) {
            Copy-Item (Join-Path $src 'notify.ps1'), (Join-Path $src 'cooked.cs'), (Join-Path $src 'cooked.ps1') $data -Force
            Copy-Item (Join-Path $src 'INSTALLED.md') (Join-Path $data 'README.md') -Force
            Copy-Item (Join-Path $voices '*.json') (Join-Path $data 'voices') -Force
        }

        # Native helper. Build beside, then swap, so a hook holding the old exe can't break the build.
        $exe = Join-Path $data 'cooked.exe'
        $tmp = Join-Path $data "cooked.$PID.exe"
        Add-Type -TypeDefinition (Get-Content (Join-Path $data 'cooked.cs') -Raw -Encoding UTF8) `
            -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase `
            -OutputAssembly $tmp -OutputType WindowsApplication
        for ($i = 0; $i -lt 10; $i++) {
            try { Move-Item $tmp $exe -Force; break } catch { Start-Sleep -Milliseconds 300 }
        }
        if (Test-Path $tmp) { Remove-Item $tmp -Force; throw "cooked.exe is in use; close other Claude Code sessions' running hooks and retry." }

        # Click handler: a clicked toast opens cooked:?... which runs cooked.exe.
        New-Item -Path "$protoKey\shell\open\command" -Force | Out-Null
        Set-ItemProperty -Path $protoKey -Name '(default)' -Value 'URL:cooked (Claude Code)'
        Set-ItemProperty -Path $protoKey -Name 'URL Protocol' -Value ''
        Set-ItemProperty -Path "$protoKey\shell\open\command" -Name '(default)' -Value "`"$exe`" `"%1`""

        # App identity: toasts say "Claude Code" with this icon, and get their own entry in Windows Settings.
        $png = Join-Path $data 'cooked.png'
        New-Icon $png
        New-Item -Path $appKey -Force | Out-Null
        Set-ItemProperty -Path $appKey -Name 'DisplayName' -Value 'Claude Code'
        Set-ItemProperty -Path $appKey -Name 'IconUri' -Value $png

        # Config: keep what the user already tuned; apply only what was passed.
        $cfgPath = Join-Path $data 'config.json'
        $cfg = [ordered]@{ voice = 'english'; sound = ''; min_seconds = 30; skip_when_watching = $true; away_after_idle_seconds = 90 }
        if (Test-Path $cfgPath) {
            $old = Read-Json $cfgPath
            foreach ($k in @($cfg.Keys)) { if ($null -ne $old.$k) { $cfg[$k] = $old.$k } }
        }
        if ($voiceFile) {
            Copy-Item $voiceFile (Join-Path $data 'copy.json') -Force
            $cfg.voice = $voiceName
        }
        elseif (-not (Test-Path (Join-Path $data 'copy.json'))) {
            Copy-Item (Join-Path $voices 'english.json') (Join-Path $data 'copy.json') -Force
        }
        if ($Sound -eq 'default') { $cfg.sound = '' }
        elseif ($Sound -eq 'none') { $cfg.sound = 'none' }
        elseif ($Sound) {
            Get-ChildItem $data -Filter 'sound.*' | Remove-Item -Force
            $name = 'sound' + [IO.Path]::GetExtension($Sound).ToLower()
            Copy-Item $Sound (Join-Path $data $name) -Force
            $cfg.sound = $name
        }
        if ($MinSeconds -ge 0) { $cfg.min_seconds = $MinSeconds }

        $out = [ordered]@{
            _readme = @(
                'cooked settings. Edit freely; changes apply to the next notification.',
                'sound: "" = Windows default, "none" = silent, or a .mp3/.wav/.wma file in this folder.',
                'min_seconds: a "done" toast only fires if the turn took at least this long (0 = every turn).',
                'skip_when_watching: no toast while this session''s terminal tab is in front of you...',
                'away_after_idle_seconds: ...unless keyboard and mouse have been idle this long.',
                'Wording lives in copy.json. Why a toast did or did not show: .state/notify.log'
            )
        }
        foreach ($k in $cfg.Keys) { $out[$k] = $cfg[$k] }
        Out-Json $out | Set-Content $cfgPath -Encoding UTF8

        Out-Json ([ordered]@{
            ok        = $true
            data_dir  = $data
            settings  = $settings
            voice     = $cfg.voice
            sound     = if ($cfg.sound) { $cfg.sound } else { 'Windows default' }
            min_seconds = $cfg.min_seconds
            hooks     = Get-Hooks
            hooks_in_settings = Test-HooksInSettings
        })
    }

    'test' {
        if (-not (Test-Path (Join-Path $data 'notify.ps1'))) { throw 'cooked is not installed yet; run install first.' }
        $copy = Read-Json (Join-Path $data 'copy.json')
        $payload = [ordered]@{
            hook_event_name = 'Stop'; cwd = (Get-Location).Path; session_id = 'cooked-test'
            last_assistant_message = $copy.test_body
        } | ConvertTo-Json -Compress
        $env:COOKED_FORCE = '1'
        $OutputEncoding = New-Object Text.UTF8Encoding $false
        $payload | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $data 'notify.ps1')
        Remove-Item Env:COOKED_FORCE
        $last = [string](Get-Content (Join-Path $data '.state\notify.log') -Tail 1 -Encoding UTF8)
        $quiet = $last -match 'muted'
        Out-Json ([ordered]@{
            ok    = ($last -match 'shown')
            muted = $quiet
            note  = if ($quiet) { 'Toast shown, sound held back: Windows reports Do Not Disturb, Focus, a fullscreen app or a presentation.' } else { '' }
            log   = $last.Trim()
        })
    }

    'uninstall' {
        Stop-Cooked
        try {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            [Windows.UI.Notifications.ToastNotificationManager]::History.Clear($appId)
        } catch { }
        Remove-Item $protoKey -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $appKey -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $data) {
            try { Remove-Item $data -Recurse -Force }
            catch { Start-Sleep -Milliseconds 800; Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Out-Json ([ordered]@{
            ok                = -not (Test-Path $data)
            removed           = @($data, $protoKey, $appKey)
            hooks_in_settings = Test-HooksInSettings
        })
    }
}
