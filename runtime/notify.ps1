# cooked: Claude Code -> Windows toast. Runs on the Stop and Notification hooks;
# UserPromptSubmit runs `cooked.exe --mark` so Stop knows how long the turn took.
# Reads the hook's JSON payload from stdin. Wording: copy.json. Behaviour: config.json.
# Rule: the title carries the voice, the body carries the real content.
# Clicking a toast opens a cooked: link, which cooked.exe turns into "jump to this session's tab".
# Why a toast did or didn't show: .state\notify.log

$ErrorActionPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.Encoding]::UTF8

$raw  = [Console]::In.ReadToEnd()
$data = $null
if ($raw) { $data = $raw | ConvertFrom-Json }

$copy     = Get-Content (Join-Path $PSScriptRoot 'copy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg      = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$exe      = Join-Path $PSScriptRoot 'cooked.exe'
$stateDir = Join-Path $PSScriptRoot '.state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$native = $false
if (Test-Path $exe) { try { [void][Reflection.Assembly]::LoadFrom($exe); $native = $true } catch { } }

$event  = if ($data -and $data.hook_event_name) { [string]$data.hook_event_name } else { 'Stop' }
$type   = if ($data) { [string]$data.notification_type } else { '' }
$msg    = if ($data) { [string]$data.message } else { '' }
$folder = if ($data -and $data.cwd) { Split-Path $data.cwd -Leaf } else { '' }
$sid    = if ($data -and $data.session_id) { [string]$data.session_id }
          elseif ($data -and $data.transcript_path) { [IO.Path]::GetFileNameWithoutExtension($data.transcript_path) }
          else { 'unknown' }
$now    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$dry    = [bool]$env:COOKED_DRYRUN   # testing: decide and print, show nothing
$force  = [bool]$env:COOKED_FORCE    # testing: skip every filter below

$appId = 'Cooked.ClaudeCode'
if (-not (Test-Path "HKCU:\Software\Classes\AppUserModelId\$appId")) {
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
}
$group = 'cooked'
$tag   = ($sid -replace '[^A-Za-z0-9]', '')
if ($tag.Length -gt 16) { $tag = $tag.Substring(0, 16) }

# ---------- helpers ----------
function Pick($list) { if ($list) { $list | Get-Random } else { '' } }

function Clean($s, $max) {
    $s = ([string]$s -replace '[`*#>]', '' -replace '\s+', ' ').Trim()
    if ($s.Length -gt $max) {
        $cut = $s.Substring(0, $max - 3)
        $sp  = $cut.LastIndexOf(' ')
        if ($sp -gt $max / 2) { $cut = $cut.Substring(0, $sp) }
        $s = $cut.TrimEnd(' ', ',', '.', ':', '-') + '...'
    }
    $s
}

function Format-Duration($s) {
    if ($s -lt 60) { return "${s}s" }
    if ($s -lt 3600) { return '{0}m {1}s' -f [Math]::Floor($s / 60), ($s % 60) }
    '{0}h {1}m' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60)
}

function Note($what) {
    $log  = Join-Path $stateDir 'notify.log'
    $line = '{0}  {1,-12} {2,-18} {3}  {4}' -f (Get-Date -Format 's'), $event, $type, $sid.Substring(0, [Math]::Min(8, $sid.Length)), $what
    if ($dry) { "[$what]" }
    Add-Content $log $line -Encoding UTF8
    if ((Get-Item $log).Length -gt 200KB) { Get-Content $log -Tail 500 -Encoding UTF8 | Set-Content $log -Encoding UTF8 }
}

# Per-session state: transcript scan offset, session titles, last stop time and reply.
$stateFile = Join-Path $stateDir "$sid.json"
$state = @{ offset = [long]0; custom = ''; ai = ''; lastStop = [long]0; lastMsg = '' }
if (Test-Path $stateFile) {
    $j = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j) {
        $state.offset = [long]$j.offset; $state.lastStop = [long]$j.lastStop
        $state.custom = [string]$j.custom; $state.ai = [string]$j.ai; $state.lastMsg = [string]$j.lastMsg
    }
}
function Save-State { $state | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8 }

# Session title as shown on the terminal tab: the /rename title, else Claude's auto title.
# Reads only the transcript bytes added since last time, so a big transcript is scanned in full once.
function Get-SessionName {
    $tp = $data.transcript_path
    if (-not ($tp -and (Test-Path $tp))) { return '' }
    $fs = [IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt $state.offset) { $state.offset = [long]0; $state.custom = ''; $state.ai = '' }
        [void]$fs.Seek($state.offset, 'Begin')
        $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd()
        $state.offset = $fs.Position
    } finally { $fs.Dispose() }
    $ms = [regex]::Matches($text, '(?m)^\{"type":"(custom|ai)-title".*$')
    $gotC = $false; $gotA = $false
    for ($i = $ms.Count - 1; $i -ge 0 -and -not ($gotC -and $gotA); $i--) {
        $kind = $ms[$i].Groups[1].Value
        if (($kind -eq 'custom' -and $gotC) -or ($kind -eq 'ai' -and $gotA)) { continue }
        $o = $ms[$i].Value.TrimEnd() | ConvertFrom-Json
        if ($kind -eq 'custom' -and $o.customTitle) { $state.custom = $o.customTitle; $gotC = $true }
        if ($kind -eq 'ai' -and $o.aiTitle) { $state.ai = $o.aiTitle; $gotA = $true }
    }
    if ($state.custom) { $state.custom } else { $state.ai }
}

# Last assistant text, from the payload or (older Claude Code) the transcript.
function Get-LastReply {
    if ($data.last_assistant_message) { return [string]$data.last_assistant_message }
    if (-not ($data.transcript_path -and (Test-Path $data.transcript_path))) { return '' }
    $lines = Get-Content $data.transcript_path -Tail 300 -Encoding UTF8
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $m = $lines[$i] | ConvertFrom-Json
        if ($m.type -ne 'assistant') { continue }
        $txt = ($m.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' '
        if ($txt.Trim()) { return $txt }
    }
    ''
}

# Drop this session's earlier toast (e.g. a permission ask already answered at the terminal).
function Clear-Toast {
    if ($dry) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($tag, $group, $appId)
    } catch { }
}

# ---------- decide ----------
# The idle reminder fires ~60s after Stop and only repeats it.
if ($event -eq 'Notification' -and $type -eq 'idle_prompt') { Note 'skip: idle reminder'; exit 0 }

$session  = if ($data) { Get-SessionName } else { '' }
$duration = ''
$reply    = ''

if ($event -eq 'Stop' -and $force) { $reply = Get-LastReply }
elseif ($event -eq 'Stop') {
    $reply     = Get-LastReply
    $replyKey  = Clean $reply 180
    $startFile = Join-Path $stateDir "$sid.start"
    $start     = if (Test-Path $startFile) { [long](Get-Content $startFile -Raw) } else { [long]0 }
    $prevStop  = $state.lastStop; $prevMsg = $state.lastMsg
    $state.lastStop = $now; $state.lastMsg = $replyKey

    if ($start -gt $prevStop) {
        $elapsed  = [int](($now - $start) / 1000)
        $duration = Format-Duration $elapsed
        if ($elapsed -lt [int]$cfg.min_seconds) {
            Save-State; Clear-Toast; Note "skip: quick turn ($duration)"; exit 0
        }
    }
    elseif (-not $replyKey -or $replyKey -eq $prevMsg) {
        # No prompt since the last stop and nothing new said: /clear, /compact, a repeated stop.
        Save-State; Note 'skip: no new turn'; exit 0
    }
}

$hwnd = if ($native) { [Cooked]::TerminalWindow($PID) } else { 0 }
if ($cfg.skip_when_watching -and $native -and -not $force) {
    $idle = [Cooked]::IdleSeconds()
    if ($idle -lt [int]$cfg.away_after_idle_seconds -and [Cooked]::Watching($hwnd, $session)) {
        if ($event -eq 'Stop') { Save-State }
        Clear-Toast; Note "skip: you're on this tab (idle ${idle}s)"; exit 0
    }
}

# ---------- compose ----------
$label = if ($session) { Clean $session 32 } elseif ($folder) { Clean $folder 20 } else { 'Claude' }

if ($event -eq 'Notification' -and ($type -eq 'permission_prompt' -or $msg -match 'permission to use')) {
    $tool = if ($msg -match 'permission to use (.+)$') { $Matches[1].Trim() } else { 'a tool' }
    if ($tool -match '^mcp__(.+?)__(.+)$') { $tool = "$($Matches[1] -replace '^claude_ai_', ''): $($Matches[2])" }
    $title = $copy.needs_prefix + (Pick $copy.permission_titles)
    $body  = (Pick $copy.permission_bodies) -replace '\{tool\}', $tool
}
elseif ($event -eq 'Notification' -and $type -eq 'auth_success') {
    $title = $copy.done_prefix + (Pick $copy.auth_titles)
    $body  = $msg
}
elseif ($event -eq 'Notification') {
    $title = $copy.needs_prefix + (Pick $copy.question_titles)
    # Keep a specific message (e.g. an MCP server's question) as the body; swap only generic ones.
    $generic = (-not $msg) -or ($msg -match '^Claude (is waiting|needs your|has a question|is asking)')
    $body = if ($generic) { Pick $copy.question_bodies } else { $msg }
}
else {
    $title = $copy.done_prefix + (Pick $copy.done_titles)
    $body  = if ($reply.Trim()) { $reply } else { Pick $copy.done_body_fallback }
}

$title = $title -replace '\{session\}', $label -replace '\{project\}', $label
$body  = Clean $body 180
$foot  = (@($duration, $folder) | Where-Object { $_ }) -join ('  ' + [char]0x00B7 + '  ')

$launch = "cooked:?hwnd=$hwnd"
if ($session) { $launch += '&tab=' + [Uri]::EscapeDataString($session) }

# sound: "" = Windows default, "none" = silent, otherwise a file next to this script.
$snd    = if ($cfg.sound -and $cfg.sound -ne 'none') { Join-Path $PSScriptRoot $cfg.sound } else { '' }
$ownSnd = $native -and $snd -and (Test-Path $snd)

if ($dry) { "$title | $body | $foot | $launch"; if ($event -eq 'Stop') { Save-State }; Note 'shown (dry run)'; exit 0 }

# ---------- show ----------
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

$e = { param($s) [Security.SecurityElement]::Escape([string]$s) }
$footXml  = if ($foot) { "<text placement=`"attribution`">$(& $e $foot)</text>" } else { '' }
$audioXml = if ($ownSnd -or $cfg.sound -eq 'none') { '<audio silent="true"/>' } else { '<audio src="ms-winsoundevent:Notification.Default"/>' }
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml("<toast activationType=`"protocol`" launch=`"$(& $e $launch)`"><visual><binding template=`"ToastGeneric`"><text>$(& $e $title)</text><text>$(& $e $body)</text>$footXml</binding></visual>$audioXml</toast>")

$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
$toast.Tag = $tag; $toast.Group = $group     # same session -> replaces its previous toast
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)

$why = 'shown'
if ($ownSnd) {
    if ([Cooked]::Quiet()) { $why = 'shown, muted (' + [Cooked]::QuietDetail() + ')' }
    else { [void][Diagnostics.Process]::Start($exe, "--play `"$snd`"") }
}
if ($event -eq 'Stop') { Save-State }
Note $why
exit 0
