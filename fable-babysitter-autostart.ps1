<#
  fable-babysitter-autostart.ps1
  Called from the Claude Code SessionStart hook so the babysitter is up whenever Claude is.

  A SessionStart hook runs as a CHILD of the claude.exe that started -> it inherits that
  session's integrity level. So if you launched the session elevated (gsudo / elevated
  terminal), this runs elevated and the babysitter it spawns is elevated too -> it can
  AttachConsole to that elevated session. Non-elevated session -> non-elevated babysitter.
  (That's the "match the session's perms" behaviour you asked for; no explicit gsudo here.)

  The babysitter self-guards with a mutex, so firing this on every session start is safe:
  a duplicate exits immediately. We still OpenExisting-check first to avoid a window flash.
#>
$ErrorActionPreference = 'SilentlyContinue'

# already running? (mutex held by a live watcher) -> nothing to do
try {
  $m = [System.Threading.Mutex]::OpenExisting('Global\FableBabysitterRunning')
  if ($m) { $m.Dispose(); exit 0 }
} catch { }   # OpenExisting throws when it doesn't exist -> not running -> launch below

$script = Join-Path $PSScriptRoot 'fable-babysitter.ps1'
if (-not (Test-Path $script)) { exit 0 }

# launch in its own minimized window (its own console for the watcher log + Ctrl+C).
# -WindowStyle Minimized keeps it out of the way; restore it from the taskbar to watch/stop.
Start-Process -FilePath 'powershell.exe' `
  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) `
  -WindowStyle Minimized
exit 0
