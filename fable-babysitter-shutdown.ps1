<#
  fable-babysitter-shutdown.ps1
  Claude Code SessionEnd hook. Stops the babysitter when the LAST Claude session closes,
  so it doesn't linger after you're done.

  It fires on every session end but only acts when no OTHER Claude session remains. The
  ending session's claude.exe may still be alive (it's our parent as the hook runs), so
  "1 or fewer" means we're the last one out.
#>
$ErrorActionPreference = 'SilentlyContinue'

$claude = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'")
if ($claude.Count -gt 1) { exit 0 }   # other sessions still open -> leave the watcher running

# last session out: stop the watcher(s). Each releases its mutex on exit; its per-poll
# -Scan child is transient and dies on its own.
$watchers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -like '*fable-babysitter.ps1*' -and $_.CommandLine -notlike '*-Scan*' -and $_.CommandLine -notlike '*-Install*' })
foreach ($w in $watchers) { try { Stop-Process -Id $w.ProcessId -Force } catch {} }
exit 0
