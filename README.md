# fable-babysitter

[![License: MIT](https://img.shields.io/badge/license-MIT-B8860B?style=flat-square&labelColor=0C1E3C)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows-1E3A5F?style=flat-square&labelColor=0C1E3C)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-00B4D8?style=flat-square&labelColor=0C1E3C)
![Made for Claude Code](https://img.shields.io/badge/made%20for-Claude%20Code-00B4D8?style=flat-square&labelColor=0C1E3C)

Auto-dismiss **Fable 5 safeguard false-flags** in [Claude Code](https://claude.com/claude-code) so long, unattended runs don't stall — plus ride out account usage-limits and keep runaway context in check.

When you run Claude Code on Fable, the model's safeguards periodically flag safe, normal content:

```
● API Error: Fable 5's safeguards flagged this message (…/legal/aup). They may flag safe, normal
  content as well. … Claude Code can't respond to this request with Fable 5.
  Double press esc to edit your last message, or try a different model with /model.
  Request ID: req_011Ccn…
```

The fix is just to send `Continue Generating.` — but doing that by hand across several tabs, all day, is miserable. This watches every Claude Code session on the machine and does it for you, without stealing focus or touching the tab you're actually working in.

> Windows only. It reads and writes each session's console directly, so it works even while you're in a full-screen game — no Alt-Tab, no focus theft.

---

## What it does

- **Auto-continues Fable flags** — detects the flag on each session's screen and types `Continue Generating.` + Enter straight into that session.
- **Every tab, named or not** — works per-process, so a brand-new untitled tab is covered the moment it starts.
- **Scroll-proof** — scrolling a session up to an old flag won't trigger a false send (a JSONL transcript check vetoes stale/scrolled flags).
- **Rides out usage limits** — when you hit the account-wide `session limit`, it holds *all* sessions and probes until the cap lifts, then resumes.
- **Auto `/compact`** — after a long unbroken streak of continues to one session, it sends `/compact` instead to shrink the runaway context, then carries on.
- **Yields to you** — never injects while a session is generating, while you're typing, or onto a queued message. Take a tab over by hand and it backs off.
- **Never cross-fires** — each send goes to the exact process that's flagged; it can't leak into another session.
- **Live TUI** — an optional control-surface dashboard showing every session's state at a glance.

---

## The control surface (`-TUI`)

```
  FABLE-BABYSITTER    4 sessions | poll 2s | maxsends:inf | compact:30 | 20:31:04
  ------------------------------------------------------------------------------
  PID     SESSION                    STATE           STREAK  MAP
  10340   api-refactor               > continue      7       y
  14268   e2e-suite                  > /compact      30      y
  9140    docs-pass                  . scroll        0       y
  13384   an-unnamed-tab               working       0       -

  recent:
    [20:31:02] FLAG e2e-suite streak 30
    [20:31:00] COMPACT sent -> /compact

  p = pause/resume    q = quit
```

`MAP` = whether the session was matched to its transcript (only needed for the scroll gate / usage-limit read; `-` tabs are still fully covered by the screen).

### Keys

Works in the dashboard or the plain log view:

| Key | Action |
|-----|--------|
| `p` / `space` | **Pause / resume.** Paused it keeps watching and reporting state — it just stops sending. Handy when you want to drive a session by hand. |
| `q` | Quit |

---

## How it works

**Screen is the control surface.** For each `claude.exe`, it `AttachConsole(pid)` + `ReadConsoleOutput` to read *that* session's own screen and detect the flag — no window handles, no UI Automation, no mapping. That's why every tab is covered and it never cross-fires. Injection is the mirror image: `AttachConsole(pid)` + `WriteConsoleInput` types the reply into that pid's console input buffer, so no window ever needs focus.

**The JSONL transcript is a correctness overlay,** used for two things only:

1. **Scroll gate.** Claude Code writes every turn (and every API error) to a per-session transcript under `%USERPROFILE%\.claude\projects\…\<sessionId>.jsonl`. If a session can be mapped to its transcript and the transcript's tail says it already moved *past* the flag (it's working/idle), an on-screen flag is scrollback and is suppressed. Unmapped tabs skip the gate — the screen wins — so nothing is ever missed.
2. **Usage limit.** The account-wide `session limit` is read from the transcript (with a screen-banner fallback).

The console work (which needs `FreeConsole`) runs in a short-lived hidden child process each poll; the watcher keeps its own console for the log / dashboard.

---

## Requirements

- Windows 10/11, PowerShell 5.1 or PowerShell 7.
- **Run it at the same elevation as your Claude Code tabs.** `AttachConsole` can only attach to a console at your own integrity level or lower — so if your Claude tabs run elevated, run this elevated too (e.g. with [`gsudo`](https://github.com/gerardog/gsudo)). It prints a loud hint if it can't attach to anything.

---

## Usage

```powershell
# watch every Claude Code session, continue any Fable flag
powershell -ExecutionPolicy Bypass -File .\fable-babysitter.ps1

# elevated (match elevated Claude tabs)
gsudo powershell -ExecutionPolicy Bypass -File .\fable-babysitter.ps1

# live dashboard
gsudo powershell -ExecutionPolicy Bypass -File .\fable-babysitter.ps1 -TUI

# see what every session shows, send nothing
.\fable-babysitter.ps1 -Diag

# detect + log but don't send
.\fable-babysitter.ps1 -DryRun

# only act on sessions whose screen mentions this
.\fable-babysitter.ps1 -TitleMatch "e2e-suite"

# never touch a specific session
.\fable-babysitter.ps1 -ExcludePid 12345
```

### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `-Reply` | `Continue Generating.` | Text sent to dismiss a flag |
| `-IntervalSec` | `2` | Poll interval |
| `-TargetProc` | `claude.exe` | Process name to watch |
| `-TitleMatch` | *(all)* | Only act on sessions whose screen contains this |
| `-ExcludePid` | *(none)* | PIDs to never touch |
| `-MaxSends` | `0` (unlimited) | Sends per distinct flag |
| `-RetrySec` | `2` | Min gap between retries of the same flag |
| `-CompactAfter` | `30` | After this many straight continues to one session, send `-CompactCmd` instead (`0` = off) |
| `-CompactCmd` | `/compact` | What to send when the streak trips |
| `-StreakGapSec` | `300` | A quiet gap longer than this resets a session's streak |
| `-ProbeSec` | `180` | While usage-limited, send one continue this often to test if the cap lifted |
| `-TUI` | | Live control-surface dashboard |
| `-Install` | | First-boot: add the auto-start hook to `~/.claude/settings.json`, then launch |
| `-Diag` | | Print each session's state; send nothing |
| `-DryRun` | | Detect + log but don't send |

---

## Auto-start on every Claude session

Run once with `-Install` and a babysitter will come up automatically with every Claude Code session — no JSON editing:

```powershell
gsudo powershell -ExecutionPolicy Bypass -File .\fable-babysitter.ps1 -Install
```

This merges two hooks into `~/.claude/settings.json` (idempotent, backs the file up first and rolls back if the write isn't valid JSON), then launches one now:

- **SessionStart** → `fable-babysitter-autostart.ps1` — brings a babysitter up with each session. Because a hook runs as a child of `claude.exe` it inherits that session's integrity (start elevated → it launches elevated). A mutex guard means only one watcher ever runs.
- **SessionEnd** → `fable-babysitter-shutdown.ps1` — stops the babysitter when the **last** Claude session closes, so it doesn't linger. (It fires on every session end but only acts when no other `claude.exe` remain.)

<details><summary>Prefer to wire it by hand?</summary>

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\fable-babysitter-autostart.ps1\"",
            "async": true
          }
        ]
      }
    ]
  }
}
```
</details>

---

## Caveats

- **Windows only** (uses Win32 console APIs).
- Detection off the transcript lags the screen slightly, but the screen is the control surface, so continues fire in real time; the transcript only vetoes scroll.
- For an unnamed tab that shares a directory with another session, the scroll gate may not engage (it can't always pick the right transcript) — that tab is still fully continued off its screen; it just doesn't get the extra scroll protection.
- If your Claude tabs run elevated and this doesn't, it attaches to nothing (it says so in the log). Run it elevated.

---

## License

MIT — see [LICENSE](LICENSE).
