<#
  fable-babysitter.ps1  —  auto-dismisses Fable false-flags so you don't babysit e2e runs.

  ARCHITECTURE (v5 — HYBRID: screen is the control surface, JSONL gates scroll + limits)
    CONTROL SURFACE = the screen, read per-pid. We AttachConsole(pid) + ReadConsoleOutput
    each claude.exe and detect the flag straight off THAT session's own screen. No mapping,
    no ambiguity -> every tab is covered, named or not, freshly-started or not. This is the
    authoritative "is this session flagged and should I act" signal.

    JSONL (the transcript) is the CORRECTNESS OVERLAY, used for two things only:
      1. SCROLL GATE. If we can map the session to its transcript and the transcript's
         current tail is WORKING/IDLE (the session already moved past the flag), an
         on-screen flag is scrollback -> suppress. Unmapped tabs skip the gate (screen
         wins) so they're never missed. This kills the "scroll past an old flag -> it
         fires" bug without sacrificing coverage.
      2. USAGE LIMIT. The account-wide "session limit" is read from the transcript
         (isApiErrorMessage) with a screen-banner fallback; while limited, ALL sessions
         hold and we probe every -ProbeSec to resume the moment the cap lifts.

    Mapping pid -> transcript (only needed for the two overlays): process working dir from
    its PEB -> project dir -> the session .jsonl, disambiguated by tab custom-title then by
    process-start-time. Transcripts (60MB+) are read with a fast byte-seek tail; each pid's
    resolved path is cached so steady-state polls are ~instant.

    INJECTION: AttachConsole(pid) + WriteConsoleInput types the reply (text + Enter) into
    that pid's console input buffer — no focus steal, works behind a full-screen game,
    never cross-targets another session. The attach/read/inject (needs FreeConsole) runs
    in a short-lived hidden child each poll; the watcher keeps its console for logs + Ctrl+C.

    Dedup is per distinct requestId (read off the screen flag block).

  YIELDS TO YOU
    It only injects when the session is NOT generating and the input box is EMPTY — never
    while you're typing, never onto a queued message, never mid-generation. Take a session
    over by hand and it backs off (logs "[hold]") instead of clobbering your text.

  AUTO /compact
    A per-session streak counts CONTINUOUS continues (it survives the brief no-flag
    generation phase between flags; it only resets after a quiet gap of -StreakGapSec).
    After -CompactAfter (default 30) straight sends to one session it sends -CompactCmd
    ("/compact") to shrink the runaway context, then resets. Set -CompactAfter 0 to disable.

  USAGE LIMIT (account-wide)
    If any session shows "You've hit your session limit ... resets 4:50pm", that cap
    is account-wide, so it HOLDS every session (no continues — they'd just re-hit it).
    The banner's clock isn't trusted for scheduling (it can be stale / a different tz
    / already past while you're still limited). Instead it holds quietly and every
    -ProbeSec (default 180s) sends ONE Continue to test if the cap lifted; the instant
    a probe gets through (banner gone) it resumes normal watching. The banner time is
    shown in the log as info only.

  USAGE
    powershell -ExecutionPolicy Bypass -File .\fable-babysitter.ps1
    # only ACT on sessions whose screen mentions this (scope to your Fable tabs!):
    .\fable-babysitter.ps1 -TitleMatch "perf-optimisation"
    # never touch a specific session (e.g. one you're driving by hand):
    .\fable-babysitter.ps1 -ExcludePid 13384
    # see what every session shows, send nothing:
    .\fable-babysitter.ps1 -Diag
    # detect + log but don't send:
    .\fable-babysitter.ps1 -DryRun

  ELEVATION: AttachConsole can only attach to a console at your own integrity level
  or lower. If your Claude tabs run elevated (elevated terminal), run this script
  elevated too (e.g. `gsudo powershell -File .\fable-babysitter.ps1`) or it will
  attach to nothing and silently do nothing. It now logs a loud hint if that happens.

  NOTE: if you run this while a watched session is on-screen *discussing* Fable flags
  (like the one that built this script), it can match quoted flag text. Scope with
  -TitleMatch / -ExcludePid to your real Fable e2e tabs.

  Ctrl+C to stop.
#>

[CmdletBinding()]
param(
  [int]      $IntervalSec = 2,
  [string]   $Reply       = "Continue Generating.",
  [string]   $TargetProc  = "claude.exe",   # process whose consoles we watch
  [string]   $TitleMatch  = "",             # only ACT on sessions whose screen text contains this (scope)
  [int[]]    $ExcludePid  = @(),            # never touch these pids
  [int]      $BlockLines  = 14,             # lines above the Request ID that must read as a Fable flag
  [int]      $MaxSends    = 0,              # sends per distinct flag; 0 = unlimited (keep hammering a stuck flag)
  [int]      $RetrySec    = 2,              # re-send no sooner than this while a flag persists, and only if not visibly working
  [int]      $CompactAfter = 30,            # after this many straight sends to one session, send -CompactCmd instead (0 = off)
  [string]   $CompactCmd   = "/compact",    # what to send when the streak trips (shrinks the runaway context)
  [int]      $ProbeSec     = 180,           # while usage-limited, send one Continue this often to test if the cap lifted
  [int]      $StreakGapSec = 300,           # a quiet gap longer than this (no continue) resets a session's streak
  [switch]   $TUI,                          # live control-surface dashboard instead of a scrolling log
  [switch]   $Install,                      # first-boot: add the SessionStart auto-start hook, then launch
  [switch]   $Diag,                         # print what every session shows each poll; sends nothing
  [switch]   $DryRun,                       # detect + log but don't send

  # --- internal: the hidden per-poll console worker (do not pass by hand) ---
  [switch]   $Scan,
  [string]   $InFile        = "",
  [string]   $OutFile       = "",
  [string]   $ExcludePidCsv = "",
  [string]   $ReplyB64      = "",           # reply passed base64 (Start-Process won't quote spaced args)
  [string]   $TitleMatchB64 = "",
  [string]   $CompactCmdB64 = ""
)

# --- pure helpers (used by the worker; cheap, defined for both modes) -------
function LastN($arr, $n) { if ($arr.Count -le $n) { return $arr } return $arr[($arr.Count - $n)..($arr.Count - 1)] }

# ---- transcript (JSONL) detection: authoritative + scroll-immune -----------
function Encode-Cwd([string]$p) { ($p.TrimEnd('\', '/') -replace '[:\\/.]', '-') }

function Get-TranscriptTail([string]$File, [int]$Bytes) {
  # fast byte-seek tail read (Get-Content -Tail is O(filesize) on 60MB+ transcripts)
  try {
    $fs = [System.IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
    try {
      $len = $fs.Length; $take = [Math]::Min($Bytes, $len); $null = $fs.Seek($len - $take, 'Begin')
      $buf = New-Object byte[] $take; $null = $fs.Read($buf, 0, $take)
      return @{ text = [System.Text.Encoding]::UTF8.GetString($buf); partial = ($take -lt $len) }
    } finally { $fs.Close() }
  } catch { return $null }
}

function Get-TranscriptTitle([string]$File) {
  $t = Get-TranscriptTail $File 131072
  if (-not $t) { return '' }
  $m = [regex]::Matches($t.text, '"customTitle"\s*:\s*"([^"]+)"')
  if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value }
  return ''
}

function Resolve-Transcript {
  # pid's cwd -> project dir -> the session's .jsonl. When a dir holds several live
  # sessions, disambiguate by tab title, then by process start time (a session's
  # transcript is created when its process starts). Returns "" only if truly unsure.
  param([string]$Root, [string]$Cwd, [string]$Title, [string]$Cached, [datetime]$PidStart)
  if ($Cached -and (Test-Path $Cached)) { return $Cached }
  if (-not $Cwd) { return "" }
  $proj = Join-Path $Root (Encode-Cwd $Cwd)
  if (-not (Test-Path $proj)) { return "" }
  $cut = (Get-Date).AddMinutes(-30)
  $files = @(Get-ChildItem "$proj\*.jsonl" -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -gt $cut } | Sort-Object LastWriteTime -Descending)
  if ($files.Count -eq 0) { return "" }
  if ($files.Count -eq 1) { return $files[0].FullName }
  # (a) exact tab-title match
  if ($Title -and $Title -ne '?') {
    foreach ($f in $files) { if ((Get-TranscriptTitle $f.FullName) -eq $Title) { return $f.FullName } }
  }
  # (b) closest transcript-creation-time to the process start time (handles untitled + fresh sessions)
  if ($PidStart -and $PidStart -gt [datetime]::MinValue) {
    $best = $null; $bestDiff = [double]::MaxValue
    foreach ($f in $files) {
      $diff = [Math]::Abs(($f.CreationTime - $PidStart).TotalSeconds)
      if ($diff -lt $bestDiff) { $bestDiff = $diff; $best = $f }
    }
    if ($best -and $bestDiff -le 180) { return $best.FullName }
  }
  return ""   # still ambiguous -> don't guess (never cross-fire)
}

function Read-TranscriptState {
  # Classify the session's CURRENT state from the TAIL of its transcript (scroll-immune):
  #   FABLE_FLAG / USAGE_LIMIT / API_ERROR / WORKING / IDLE / UNKNOWN  (+ requestId for dedup).
  param([string]$File)
  $r = @{ state = 'UNKNOWN'; req = '' }
  if (-not $File) { return $r }
  $t = Get-TranscriptTail $File 200000
  if (-not $t) { return $r }
  $lines = $t.text -split "`n"
  if ($t.partial -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }  # drop partial first line
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $l = $lines[$i].Trim(); if (-not $l) { continue }
    try { $o = $l | ConvertFrom-Json } catch { continue }
    if ($o.type -ne 'assistant' -and $o.type -ne 'user') { continue }   # skip queue-ops / metadata
    if ($o.isApiErrorMessage -eq $true) {
      $c = $o.message.content
      $txt = if ($c -is [string]) { $c } else { ($c | Where-Object { $_.text } | Select-Object -First 1).text }
      $r.req = [string]$o.requestId
      if     ($txt -match 'safeguards flagged|legal/aup') { $r.state = 'FABLE_FLAG' }
      elseif ($txt -match 'session limit')                { $r.state = 'USAGE_LIMIT' }
      else                                                { $r.state = 'API_ERROR' }
      return $r
    }
    if ($o.type -eq 'user' -or $o.message.stop_reason -eq 'tool_use') { $r.state = 'WORKING'; return $r }
    $r.state = 'IDLE'; return $r
  }
  return $r
}

# ---- screen (the CONTROL SURFACE): read THIS pid's own screen, any tab, no mapping ----
function Test-Flag {
  # Newest flag on screen: last "Request ID: req_..." whose preceding block reads as a Fable flag.
  param([string]$Screen, [int]$BlockLines)
  if (-not $Screen) { return @{ hit = $false; req = "" } }
  $lines  = @($Screen -split "`n")
  $reqIdx = -1; $req = ""
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $m = [regex]::Match($lines[$i], 'Request ID:\s*(req_[A-Za-z0-9]+)')
    if ($m.Success) { $reqIdx = $i; $req = $m.Groups[1].Value; break }
  }
  if ($reqIdx -lt 0) { return @{ hit = $false; req = "" } }
  $start = [Math]::Max(0, $reqIdx - $BlockLines + 1)
  $block = ($lines[$start..$reqIdx]) -join "`n"
  $hasFable = $block -match 'Fable'
  $hasErr   = $block -match '(API Error|safeguards flagged|different model with /model|can''t respond to this request)'
  return @{ hit = ($hasFable -and $hasErr); req = $req }
}

function Test-Busy {
  # Actively generating right now? (Not just a finished "Worked for 2m 23s" summary.)
  param([string]$Screen)
  if (-not $Screen) { return $false }
  $tail = (LastN @($Screen -split "`n") 26) -join "`n"
  $up = [char]0x2191; $dn = [char]0x2193; $ell = [char]0x2026
  $s1 = [char]0x2731; $s2 = [char]0x273F
  if ($tail -match 'Waiting for \d')                { return $true }
  if ($tail -match '\(\d+m?\s*\d*s\b')              { return $true }
  if ($tail -match ([regex]::Escape($up) + '\s*\d')) { return $true }
  if ($tail -match ([regex]::Escape($dn) + '\s*\d')) { return $true }
  if ($tail -match ('[' + $s1 + '-' + $s2 + '][^\r\n]*' + $ell)) { return $true }
  return $false
}

function Test-Limit {
  # Screen-side detection of the cap actually being HIT (fallback for the transcript on unmapped tabs).
  # Must NOT trip on the periodic "you're at X% of your usage limit" notice or the session-start
  # "…weekly usage limit… if you hit your limit… usage credits" info banner — those say "usage limit"
  # but aren't a block. Match only the real hit line: "hit your session/usage/weekly limit", or the
  # "/usage-credits to finish" prompt shown when you're actually blocked.
  param([string]$Screen)
  if (-not $Screen) { return $false }
  $tail = (LastN @($Screen -split "`n") 20) -join "`n"
  return [bool]($tail -match '(?i)hit your (session|usage|weekly) limit|/usage-credits to finish')
}

function Get-InputLine {
  # The text currently in the input box (line with the ❯ prompt, below the tab divider).
  # "" = empty box; $null = couldn't locate the box.
  param([string]$Screen)
  if (-not $Screen) { return $null }
  $d = [char]0x2500; $mk = [char]0x276F
  $lines = @($Screen -split "`n")
  $divIdx = -1
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match "$d{5,}" -and $lines[$i] -match '\w') { $divIdx = $i; break }
  }
  if ($divIdx -lt 0) { return $null }
  for ($i = $divIdx + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "^\s*[$mk>]\s?(.*)$") { return ($matches[1].Trim()) }
  }
  return $null
}

function Test-Ready {
  # Safe to inject? Only when NOT generating and the input box is empty — never clobber
  # what you're typing, never pile onto a queued message, never inject mid-generation.
  param([string]$Screen)
  if (Test-Busy $Screen) { return $false }
  $inp = Get-InputLine $Screen
  if ($null -eq $inp) { return $true }
  return ($inp -eq '')
}

function Get-SessionName {
  param([string]$Screen)
  if (-not $Screen) { return "?" }
  # Claude Code draws a "──────── <tab name> ──" divider above the prompt.
  $d  = [char]0x2500
  $re = "$d{5,}.*?([\w][\w .:\-]{1,38}?)\s*$d"
  $m  = [regex]::Matches($Screen, $re)
  for ($i = $m.Count - 1; $i -ge 0; $i--) {
    $v = $m[$i].Groups[1].Value.Trim()
    if ($v -and $v -notmatch '^[\s\W]+$') { return $v }
  }
  return "?"
}

# ===========================================================================
# WORKER (-Scan): all AttachConsole read/inject for one poll. Uses dedup state
# from -InFile, writes {logs,state} JSON to -OutFile. Same file, one script.
# ===========================================================================
if ($Scan) {
  if ($ReplyB64)      { $Reply      = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ReplyB64)) }
  if ($TitleMatchB64) { $TitleMatch = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($TitleMatchB64)) }
  if ($CompactCmdB64) { $CompactCmd = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($CompactCmdB64)) }
  Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class ConIO {
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len, COORD c, out uint read);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);

  [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
  [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct CSBI {
    public COORD dwSize; public COORD dwCursor; public ushort wAttr; public SMALL_RECT srWindow; public COORD dwMax;
  }
  [StructLayout(LayoutKind.Sequential)] struct KEY_EVENT_RECORD {
    [MarshalAs(UnmanagedType.Bool)] public bool bKeyDown;
    public ushort wRepeatCount, wVirtualKeyCode, wVirtualScanCode, UnicodeChar; public uint dwControlKeyState;
  }
  [StructLayout(LayoutKind.Explicit)] struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD Key;
  }
  const uint GRW = 0xC0000000, SRW = 3, OPEN = 3; const ushort KEY_EVENT = 1;
  static readonly IntPtr INV = new IntPtr(-1);

  static INPUT_RECORD K(bool down, ushort ch, ushort vk) {
    var r = new INPUT_RECORD(); r.EventType = KEY_EVENT;
    r.Key.bKeyDown = down; r.Key.wRepeatCount = 1; r.Key.wVirtualKeyCode = vk;
    r.Key.wVirtualScanCode = 0; r.Key.UnicodeChar = ch; r.Key.dwControlKeyState = 0; return r;
  }

  public static string ReadScreen(int pid) {
    FreeConsole();
    if (!AttachConsole((uint)pid)) return "";
    IntPtr h = INV;
    try {
      h = CreateFileW("CONOUT$", GRW, SRW, IntPtr.Zero, OPEN, 0, IntPtr.Zero);
      if (h == INV) return "";
      CSBI ci; if (!GetConsoleScreenBufferInfo(h, out ci)) return "";
      int w = ci.dwSize.X; if (w <= 0) return "";
      var sb = new StringBuilder(); var row = new char[w];
      for (short y = ci.srWindow.T; y <= ci.srWindow.B; y++) {
        uint r; COORD c; c.X = 0; c.Y = y;
        if (ReadConsoleOutputCharacterW(h, row, (uint)w, c, out r)) { sb.Append(row, 0, (int)r); sb.Append('\n'); }
      }
      return sb.ToString();
    } finally { if (h != INV) CloseHandle(h); FreeConsole(); }
  }

  public static bool Inject(int pid, string text, bool enter) {
    FreeConsole();
    if (!AttachConsole((uint)pid)) return false;
    IntPtr h = INV;
    try {
      h = CreateFileW("CONIN$", GRW, SRW, IntPtr.Zero, OPEN, 0, IntPtr.Zero);
      if (h == INV) return false;
      var recs = new List<INPUT_RECORD>();
      foreach (char c in text) { recs.Add(K(true,(ushort)c,0)); recs.Add(K(false,(ushort)c,0)); }
      if (enter) { recs.Add(K(true,(ushort)'\r',0x0D)); recs.Add(K(false,(ushort)'\r',0x0D)); }
      uint wn; var arr = recs.ToArray();
      return WriteConsoleInputW(h, arr, (uint)arr.Length, out wn) && wn == (uint)arr.Length;
    } finally { if (h != INV) CloseHandle(h); FreeConsole(); }
  }

  // --- read a process's current working directory (to map pid -> transcript) ---
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI p, int len, out int ret);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out int read);
  [StructLayout(LayoutKind.Sequential)] struct PBI { public IntPtr R1; public IntPtr Peb; public IntPtr R2a, R2b; public IntPtr Pid; public IntPtr R3; }
  static IntPtr RP(IntPtr h, IntPtr a) { var b = new byte[8]; int r; if (!ReadProcessMemory(h, a, b, 8, out r)) return IntPtr.Zero; return (IntPtr)BitConverter.ToInt64(b, 0); }
  public static string GetCwd(int pid) {
    IntPtr h = OpenProcess(0x0410, false, pid);   // QUERY_INFORMATION | VM_READ
    if (h == IntPtr.Zero) return "";
    try {
      var p = new PBI(); int rl;
      if (NtQueryInformationProcess(h, 0, ref p, Marshal.SizeOf(p), out rl) != 0) return "";
      IntPtr pp = RP(h, (IntPtr)((long)p.Peb + 0x20));               // PEB->ProcessParameters
      if (pp == IntPtr.Zero) return "";
      var lb = new byte[2]; int r; ReadProcessMemory(h, (IntPtr)((long)pp + 0x38), lb, 2, out r);  // CurrentDirectory.DosPath.Length
      int len = BitConverter.ToUInt16(lb, 0);
      IntPtr buf = RP(h, (IntPtr)((long)pp + 0x40));                 // .Buffer
      if (buf == IntPtr.Zero || len <= 0) return "";
      var db = new byte[len]; ReadProcessMemory(h, buf, db, len, out r);
      return Encoding.Unicode.GetString(db, 0, r);
    } finally { CloseHandle(h); }
  }
}
"@

  $state = @{}
  if ($InFile -and (Test-Path $InFile)) {
    try {
      $j = Get-Content $InFile -Raw | ConvertFrom-Json
      foreach ($p in $j.PSObject.Properties) {
        if ($p.Name -eq '_global') { $state['_global'] = @{ probeAt = [string]$p.Value.probeAt; lastLog = [string]$p.Value.lastLog } }
        else { $state[$p.Name] = @{ req = [string]$p.Value.req; sends = [int]$p.Value.sends; last = [long]$p.Value.last; streak = [int]$p.Value.streak; file = [string]$p.Value.file; presume = [bool]$p.Value.presume } }
      }
    } catch {}
  }
  $exclude = @()
  if ($ExcludePidCsv) { $exclude = $ExcludePidCsv -split ',' | ForEach-Object { [int]$_ } }

  $logs    = New-Object System.Collections.ArrayList
  $actions = @{}   # per-pid action this poll (for the -TUI dashboard): sent/compact/hold/scroll/limit/probe
  $seen    = @{}
  $nowTk   = (Get-Date).Ticks

  $targets = @()
  try { $targets = @(Get-CimInstance Win32_Process -Filter "Name='$TargetProc'" -ErrorAction Stop) } catch {}

  $ProjRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude\projects'

  # Pass 1: read each session's screen (for the tab title + input box), map pid -> transcript,
  # and read the authoritative current state from the transcript tail (scroll-immune).
  $sessions = @()
  $attempted = 0; $readOK = 0
  foreach ($t in $targets) {
    $tpid = [int]$t.ProcessId
    if ($exclude -contains $tpid) { continue }
    $key = "$tpid"
    $screen = [ConIO]::ReadScreen($tpid)
    $attempted++; if ($screen) { $readOK++ }
    $name = Get-SessionName $screen
    if ($TitleMatch -and ($name -notlike "*$TitleMatch*") -and ($screen -notlike "*$TitleMatch*")) { continue }
    $seen[$key] = $true
    $cached = if ($state.ContainsKey($key)) { [string]$state[$key].file } else { "" }
    $pidStart = try { [datetime]$t.CreationDate } catch { [datetime]::MinValue }
    $file = Resolve-Transcript -Root $ProjRoot -Cwd ([ConIO]::GetCwd($tpid)) -Title $name -Cached $cached -PidStart $pidStart
    $ts   = Read-TranscriptState $file
    $sf   = Test-Flag -Screen $screen -BlockLines $BlockLines
    $lim  = ($ts.state -eq 'USAGE_LIMIT') -or (Test-Limit $screen)
    $sessions += @{ pid = $tpid; key = $key; screen = $screen; name = $name; file = $file;
                    tstate = $ts.state; treq = $ts.req; sflag = $sf.hit; sreq = $sf.req; limit = $lim }
  }

  # account-wide usage-limit state (tracked once, not per-pid)
  if (-not $state.ContainsKey('_global')) { $state['_global'] = @{ probeAt = ""; lastLog = "" } }
  $g = $state['_global']

  function Save-Result {
    $pruned = @{}
    foreach ($k in $seen.Keys) { if ($state.ContainsKey($k)) { $pruned[$k] = $state[$k] } }
    $pruned['_global'] = $g
    # per-session status for the -TUI dashboard
    $status = @()
    foreach ($s in $sessions) {
      $act = if ($actions.ContainsKey($s.key)) { $actions[$s.key] }
             elseif ($s.limit) { 'limit' } elseif ($s.sflag) { 'flag' }
             else { switch ($s.tstate) { 'WORKING' { 'working' } 'IDLE' { 'idle' } default { '-' } } }
      $strk = if ($state.ContainsKey($s.key)) { [int]$state[$s.key].streak } else { 0 }
      $status += @{ pid = $s.pid; name = $s.name; act = $act; streak = $strk; mapped = [bool]$s.file }
    }
    $res = @{ logs = @($logs); state = $pruned; status = $status }
    try { ($res | ConvertTo-Json -Depth 6 -Compress) | Set-Content -Path $OutFile -Encoding UTF8 } catch {}
  }

  if ($attempted -gt 0 -and $readOK -eq 0) {
    [void]$logs.Add(("(!) attached to 0 of {0} '{1}' console(s) - if your claude tabs run ELEVATED, start this script elevated too (e.g. gsudo)." -f $attempted, $TargetProc))
  }

  if ($Diag) {
    foreach ($s in $sessions) {
      [void]$logs.Add(("[diag] pid={0,-6} name='{1}' scrFlag={2,-5} sreq={3,-24} tstate={4,-11} limit={5,-5} map={6}" -f `
        $s.pid, $s.name, $s.sflag, $(if ($s.sreq) { $s.sreq } else { '-' }), $s.tstate, $s.limit, $(if ($s.file) { Split-Path $s.file -Leaf } else { '<unmapped>' })))
    }
  }

  # ---- account-wide usage-limit gate (state from the transcript; probe to resume) ----
  # We don't trust the banner's clock for scheduling. Instead: HOLD silently, and every
  # -ProbeSec send ONE Continue to test whether the cap lifted. Resume the instant it has.
  $now = Get-Date
  $limitShown = @($sessions | Where-Object { $_.limit }).Count -gt 0

  if ($limitShown) {
    $resetInfo = '?'
    if (-not $g.probeAt) { $g.probeAt = $now.AddSeconds($ProbeSec).ToString('o') }
    $probeAt = [datetime]::Parse($g.probeAt)
    if ($now -ge $probeAt) {
      # probe: poke each ready session once to see if the cap lifted
      [void]$logs.Add(("USAGE LIMIT - probing sessions (banner reset ~{0})" -f $resetInfo))
      foreach ($s in $sessions) {
        if (Test-Ready $s.screen) {
          $actions[$s.key] = 'probe'
          if ($Diag -or $DryRun) { [void]$logs.Add(("  would probe pid={0} -> {1}" -f $s.pid, $Reply)) }
          else { $ok = [ConIO]::Inject($s.pid, $Reply, $true); [void]$logs.Add(("  probe pid={0} -> {1} ({2})" -f $s.pid, $Reply, $(if ($ok) { 'sent' } else { 'FAIL' }))) }
        }
      }
      $g.probeAt = $now.AddSeconds($ProbeSec).ToString('o'); $g.lastLog = $now.ToString('o')
    }
    else {
      # silent hold with a ~1/min heartbeat so the log isn't spammed every poll
      $hb = (-not $g.lastLog) -or ((($now) - [datetime]::Parse($g.lastLog)).TotalSeconds -ge 55)
      if ($hb -or $Diag) {
        $mins = [Math]::Ceiling(($probeAt - $now).TotalMinutes)
        [void]$logs.Add(("USAGE LIMIT (account-wide) - holding; next probe in ~{0} min (banner reset ~{1})" -f $mins, $resetInfo))
        $g.lastLog = $now.ToString('o')
      }
    }
    foreach ($s in $sessions) { if (-not $actions.ContainsKey($s.key)) { $actions[$s.key] = 'limit' } }
    Save-Result; exit 0
  }
  elseif ($g.probeAt) {
    [void]$logs.Add("usage limit cleared - resuming normal watch")
    $g.probeAt = ""; $g.lastLog = ""
  }

  # ---- per-session flag handling: SCREEN detects (every tab, no mapping), transcript gates scroll ----
  foreach ($s in $sessions) {
    $tpid = $s.pid; $nm = $s.name; $key = $s.key
    if (-not $state.ContainsKey($key)) { $state[$key] = @{ req = ""; sends = 0; last = 0; streak = 0; file = ""; presume = $false } }
    $st = $state[$key]
    $st.file = $s.file   # cache the resolved transcript path so next poll skips re-resolution

    # RESUME AFTER /compact: a /compact just shrinks context and leaves the session idle — it does
    # NOT continue the work. So after we send /compact we flag `presume`, and once the session is
    # ready again (compaction finished, input empty) we send one Continue to pick the work back up.
    if ($st.presume) {
      if (-not (Test-Ready $s.screen)) { $actions[$key] = 'compacting'; continue }   # still compacting / busy -> wait
      $st.presume = $false; $st.last = $nowTk; $st.streak = 1
      $actions[$key] = 'sent'
      [void]$logs.Add(("RESUME pid={0} name='{1}' (post-/compact)" -f $tpid, $nm))
      if ($Diag -or $DryRun) { [void]$logs.Add("  would send -> $Reply") }
      else { $ok = [ConIO]::Inject($tpid, $Reply, $true); [void]$logs.Add(("  {0} -> {1}" -f $(if ($ok) { "sent" } else { "INJECT FAILED" }), $Reply)) }
      continue
    }

    if (-not $s.sflag) { continue }   # no flag on this pid's screen -> nothing to do (keep the loop's streak/req)

    # SCROLL GATE (JSONL): if this session is mapped AND its transcript says it already moved PAST
    # the flag (working / idle), the on-screen flag is scrollback -> suppress. Unmapped tabs skip
    # the gate (screen is authoritative), so they're never missed.
    if ($s.file -and ($s.tstate -eq 'WORKING' -or $s.tstate -eq 'IDLE')) {
      $actions[$key] = 'scroll'
      if ($Diag) { [void]$logs.Add(("  [scroll-skip] pid={0} on-screen flag but transcript is {1}" -f $tpid, $s.tstate)) }
      continue
    }

    $req = $s.sreq
    $unlimited = ($MaxSends -le 0)
    $isNew    = $req -ne $st.req
    $mayRetry = (-not $isNew) -and ($st.sends -gt 0) -and ($unlimited -or ($st.sends -lt $MaxSends)) -and `
                ((($nowTk - $st.last) / 1e7) -ge $RetrySec)
    if (-not ($isNew -or $mayRetry)) { continue }

    # Yield to the human: only inject when not generating and the input box is empty.
    if (-not (Test-Ready $s.screen)) {
      $actions[$key] = 'hold'
      if ($Diag) { [void]$logs.Add(("  [hold] pid={0} flagged but busy / input not empty (you're typing or a message is queued)" -f $tpid)) }
      continue
    }

    # streak = continuous continues to this session. It must survive the brief no-flag generation
    # phase BETWEEN flags, so we only reset it after a long quiet gap (the loop genuinely ended).
    $gapSec = if ($st.last -eq 0) { [double]::MaxValue } else { ($nowTk - $st.last) / 1e7 }
    if ($isNew -and $gapSec -gt $StreakGapSec) { $st.streak = 0 }
    if ($isNew) { $st.req = $req; $st.sends = 0 }
    $st.sends++; $st.last = $nowTk

    # after a long streak of continues, send /compact instead to shrink the runaway context
    $doCompact = ($CompactAfter -gt 0 -and $st.streak -ge $CompactAfter)
    if ($doCompact) { $sendText = $CompactCmd; $st.streak = 0; $st.presume = $true }  # resume with a Continue once it finishes
    else            { $sendText = $Reply;      $st.streak++ }
    $actions[$key] = if ($doCompact) { 'compact' } else { 'sent' }

    $cap = if ($unlimited) { "inf" } else { "$MaxSends" }
    $tag = if ($doCompact) { "COMPACT (streak >= $CompactAfter)" } elseif ($isNew) { "FLAG (streak $($st.streak))" } else { "RETRY $($st.sends)/$cap (streak $($st.streak))" }
    [void]$logs.Add(("{0} pid={1} name='{2}' req={3}" -f $tag, $tpid, $nm, $req))

    if ($Diag -or $DryRun) { [void]$logs.Add("  would send -> $sendText") }
    else {
      $ok = [ConIO]::Inject($tpid, $sendText, $true)
      [void]$logs.Add(("  {0} -> {1}" -f $(if ($ok) { "sent" } else { "INJECT FAILED" }), $sendText))
    }
  }

  Save-Result
  exit 0
}

# ===========================================================================
# WATCHER (default): spawns the worker each poll, prints its logs, keeps state.
# ===========================================================================
function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

$SettingsPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude\settings.json'
$AutoStart    = Join-Path $PSScriptRoot 'fable-babysitter-autostart.ps1'
$Shutdown     = Join-Path $PSScriptRoot 'fable-babysitter-shutdown.ps1'

function Test-HookInstalled {
  if (-not (Test-Path $SettingsPath)) { return $false }
  try { $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json } catch { return $false }
  foreach ($grp in @($j.hooks.SessionStart)) { foreach ($h in @($grp.hooks)) { if ("$($h.command)" -match 'fable-babysitter-autostart') { return $true } } }
  return $false
}

function Add-HookEntry($j, [string]$Event, [string]$ScriptPath, [string]$Marker) {
  # add a command hook for $Event -> $ScriptPath unless one already matches $Marker. Mutates $j. Returns added/present/skip.
  if (-not (Test-Path $ScriptPath)) { return 'skip' }
  if (-not $j.PSObject.Properties['hooks'] -or $null -eq $j.hooks) { $j | Add-Member hooks ([pscustomobject]@{}) -Force }
  if (-not $j.hooks.PSObject.Properties[$Event] -or $null -eq $j.hooks.$Event) { $j.hooks | Add-Member $Event @() -Force }
  foreach ($grp in @($j.hooks.$Event)) { foreach ($h in @($grp.hooks)) { if ("$($h.command)" -match $Marker) { return 'present' } } }
  $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
  $entry = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $cmd; async = $true }) }
  $j.hooks.$Event = @(@($j.hooks.$Event) + $entry)
  return 'added'
}

function Install-Hooks {
  # merge SessionStart (auto-start) + SessionEnd (shutdown) hooks into ~/.claude/settings.json;
  # idempotent, backed up + validated (rolls back if the write isn't valid JSON).
  if (-not (Test-Path $AutoStart)) { Write-Host "! can't find fable-babysitter-autostart.ps1 next to this script"; return $false }
  $dir = Split-Path $SettingsPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $j = if (Test-Path $SettingsPath) {
    try { Get-Content $SettingsPath -Raw | ConvertFrom-Json } catch { Write-Host "! settings.json is not valid JSON - fix it first, not touching it"; return $false }
  } else { [pscustomobject]@{} }
  $rs = Add-HookEntry $j 'SessionStart' $AutoStart 'fable-babysitter-autostart'
  $re = Add-HookEntry $j 'SessionEnd'   $Shutdown  'fable-babysitter-shutdown'
  if ($rs -ne 'added' -and $re -ne 'added') { Write-Host "= hooks already installed (SessionStart:$rs SessionEnd:$re)"; return $true }
  $bak = "${SettingsPath}.bak"
  if (Test-Path $SettingsPath) { Copy-Item $SettingsPath $bak -Force }
  ($j | ConvertTo-Json -Depth 100) | Set-Content -Path $SettingsPath -Encoding UTF8
  try { Get-Content $SettingsPath -Raw | ConvertFrom-Json | Out-Null }
  catch { if (Test-Path $bak) { Copy-Item $bak $SettingsPath -Force }; Write-Host "! write produced invalid JSON - restored backup, no change made"; return $false }
  Write-Host "+ hooks in settings.json  SessionStart:$rs  SessionEnd:$re  (backup: settings.json.bak)"
  return $true
}

if ($Install) {
  Write-Host "fable-babysitter - first-boot install"
  if (Install-Hooks) {
    Write-Host "  auto-starts with every Claude session; stops when the last one closes."
    Write-Host "  launching one now (minimized)..."
    try { Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $AutoStart) -WindowStyle Minimized } catch { Write-Host "  (couldn't launch now; it'll come up on your next Claude session)" }
  }
  exit 0
}

function Show-Dashboard {
  # live control-surface: one row per session + a tail of recent actions, redrawn in place.
  param($Status, $Recent, $Info)
  $w = try { [Console]::WindowWidth - 1 } catch { 99 }
  $h = try { [Console]::WindowHeight }   catch { 30 }
  $map = @{
    sent    = @('> continue', 'Green');      compact = @('> /compact', 'Cyan')
    probe   = @('> probe',     'Green');      hold    = @('. hold (you)', 'DarkYellow')
    scroll  = @('. scroll',    'DarkGray');   limit   = @('! USAGE LIMIT', 'Red')
    compacting = @('~ compacting', 'Cyan');
    flag    = @('* flagged',   'Yellow');     working = @('  working', 'Gray'); idle = @('  idle', 'DarkGray')
  }
  $lines = New-Object System.Collections.ArrayList; $cols = New-Object System.Collections.ArrayList
  $add = { param($t, $c) [void]$lines.Add($t); [void]$cols.Add($c) }
  & $add ("  FABLE-BABYSITTER    $Info") 'White'
  & $add ("  " + ('-' * [Math]::Max(1, $w - 4))) 'DarkGray'
  & $add ("  {0,-7} {1,-26} {2,-15} {3,-7} {4}" -f 'PID', 'SESSION', 'STATE', 'STREAK', 'MAP') 'DarkGray'
  foreach ($s in $Status) {
    $e = if ($map.ContainsKey($s.act)) { $map[$s.act] } else { @("  $($s.act)", 'Gray') }
    $nm = [string]$s.name; if ($nm.Length -gt 26) { $nm = $nm.Substring(0, 26) }
    & $add ("  {0,-7} {1,-26} {2,-15} {3,-7} {4}" -f $s.pid, $nm, $e[0], $s.streak, $(if ($s.mapped) { 'y' } else { '-' })) $e[1]
  }
  & $add "" 'Gray'
  & $add "  recent:" 'DarkGray'
  foreach ($ln in $Recent) { & $add ("    $ln") 'Gray' }
  & $add "" 'Gray'
  & $add "  Ctrl+C to quit" 'DarkGray'
  try { [Console]::SetCursorPosition(0, 0) } catch {}
  for ($i = 0; $i -lt $lines.Count -and $i -lt $h - 1; $i++) {
    $t = [string]$lines[$i]; if ($t.Length -gt $w) { $t = $t.Substring(0, $w) } else { $t = $t.PadRight($w) }
    Write-Host $t -ForegroundColor $cols[$i]
  }
  for ($i = $lines.Count; $i -lt $h - 1; $i++) { Write-Host (' ' * $w) }
  try { [Console]::SetCursorPosition(0, 0) } catch {}
}

# single-instance guard: the SessionStart hook may launch this many times; only one
# watcher must run (two would double-inject). The mutex is held for this process's life.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\FableBabysitterRunning')
if (-not $script:Mutex.WaitOne(0)) { Write-Host "fable-babysitter already running - exiting."; exit 0 }

$HostExe = try { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { "powershell.exe" }
$state   = @{}
$inFile  = Join-Path ([IO.Path]::GetTempPath()) ("fbaby_state_{0}.json" -f $PID)
$outFile = Join-Path ([IO.Path]::GetTempPath()) ("fbaby_out_{0}.json"   -f $PID)

if (-not $TUI) {
  $found = @()
  try { $found = @(Get-CimInstance Win32_Process -Filter "Name='$TargetProc'") } catch {}
  Log ("watching {0} session(s) of '{1}' every {2}s | scope:{3} | maxsends:{4} retry:{5}s | compact-after:{6} | diag:{7} dry:{8}" -f `
       $found.Count, $TargetProc, $IntervalSec,
       $(if ($TitleMatch) { "screen~'$TitleMatch'" } else { "ALL (scope with -TitleMatch!)" }),
       $(if ($MaxSends -le 0) { "unlimited" } else { "$MaxSends" }), $RetrySec,
       $(if ($CompactAfter -gt 0) { "$CompactAfter -> $CompactCmd" } else { "off" }), [bool]$Diag, [bool]$DryRun)
  if ($ExcludePid.Count) { Log ("excluding pids: {0}" -f ($ExcludePid -join ', ')) }
  if (-not (Test-HookInstalled)) { Log "tip: run once with -Install to auto-start on every Claude session" }
}
if ($TUI) { try { [Console]::CursorVisible = $false; Clear-Host } catch {}; $recent = New-Object System.Collections.ArrayList }

# base64 the args that may contain spaces — Start-Process -ArgumentList does NOT quote them
$replyB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Reply))

while ($true) {
  try { ($state | ConvertTo-Json -Depth 6 -Compress) | Set-Content -Path $inFile -Encoding UTF8 }
  catch { "{}" | Set-Content -Path $inFile -Encoding UTF8 }
  Remove-Item $outFile -ErrorAction SilentlyContinue

  $a = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File', $PSCommandPath, '-Scan',
         '-InFile', $inFile, '-OutFile', $outFile,
         '-ReplyB64', $replyB64, '-TargetProc', $TargetProc,
         '-BlockLines', "$BlockLines", '-MaxSends', "$MaxSends", '-RetrySec', "$RetrySec",
         '-CompactAfter', "$CompactAfter", '-ProbeSec', "$ProbeSec", '-StreakGapSec', "$StreakGapSec",
         '-CompactCmdB64', [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($CompactCmd)))
  if ($TitleMatch)        { $a += @('-TitleMatchB64', [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($TitleMatch))) }
  if ($ExcludePid.Count)  { $a += @('-ExcludePidCsv', ($ExcludePid -join ',')) }
  if ($Diag)              { $a += '-Diag' }
  if ($DryRun)            { $a += '-DryRun' }

  try { Start-Process -FilePath $HostExe -ArgumentList $a -WindowStyle Hidden -Wait -ErrorAction Stop | Out-Null }
  catch { Log "scan worker failed to launch: $_" }

  if (Test-Path $outFile) {
    try {
      $r = Get-Content $outFile -Raw | ConvertFrom-Json
      if ($TUI) {
        foreach ($ln in @($r.logs)) { if ($ln -and $ln -notmatch '^\s*\[') { [void]$recent.Add(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $ln.Trim())) } }
        while ($recent.Count -gt 12) { $recent.RemoveAt(0) }
        $info = "{0} sessions | poll {1}s | maxsends:{2} | compact:{3} | {4}" -f `
          @($r.status).Count, $IntervalSec, $(if ($MaxSends -le 0) { 'inf' } else { "$MaxSends" }),
          $(if ($CompactAfter -gt 0) { "$CompactAfter" } else { 'off' }), (Get-Date -Format 'HH:mm:ss')
        Show-Dashboard -Status @($r.status) -Recent @($recent) -Info $info
      }
      else { foreach ($ln in @($r.logs)) { if ($ln) { Log $ln } } }
      $state = @{}
      if ($r.state) {
        foreach ($p in $r.state.PSObject.Properties) {
          if ($p.Name -eq '_global') { $state['_global'] = @{ probeAt = [string]$p.Value.probeAt; lastLog = [string]$p.Value.lastLog } }
          else { $state[$p.Name] = @{ req = [string]$p.Value.req; sends = [int]$p.Value.sends; last = [long]$p.Value.last; streak = [int]$p.Value.streak; file = [string]$p.Value.file; presume = [bool]$p.Value.presume } }
        }
      }
    } catch { if (-not $TUI) { Log "could not parse worker result: $_" } }
  }

  Start-Sleep -Seconds $IntervalSec
}
