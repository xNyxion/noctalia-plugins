# AGENTS.md — nyx/radio-player

Noctalia v5 plugin: bar widget + click panel for internet radio (play/pause,
next/prev, station list). Playback via `mpv`. Working as of this writing —
read this before changing process-management or state-sharing code, the
current shape exists because two non-obvious bugs were found and fixed here.

## Files

- `plugin.toml` — manifest. One `[[widget]]` (`id="widget"`), one
  `[[service]]` (`id="radio-service"`), one `[[panel]]` (`id="player"`).
  **Entry ids must be unique across the WHOLE plugin, not just within one
  entry kind** — reusing `"player"` for both the service and the panel made
  Noctalia silently drop the entire plugin (`duplicate entry id 'player'` in
  the log, not a partial failure). If you add entries, keep every id
  plugin-wide unique.
- `service.luau` — **owns the mpv subprocess.** Source of truth for
  `currentIndex` / `playing` / `stationName`, published via `noctalia.state`.
  Listens for commands on `noctalia.state.watch("command", ...)`, runs a
  watchdog via `update()`, and accepts external control through `onIpc`.
- `widget.luau` — bar capsule, read-only view of `playing`/`stationName`,
  left-click toggles the panel.
- `panel.luau` — **pure UI, no process control.** Sends commands via
  `noctalia.state.set("command", {type=..., seq=...})`; never calls
  `noctalia.runAsync` for mpv itself.
- `translations/en.json` — all label/tooltip/notify strings.

## External control (`onIpc`)

The service answers `noctalia msg plugin nyx/radio-player:radio-service all
<event>`, with events `play [index]`, `pause`, `toggle`, `next`, `prev`, and
`status` (logs current state). A service has no output, so `all` is the only
target that reaches it — `focused` silently matches nothing. Every event
routes through `handleCommand`, the same path the panel uses, so IPC and UI
can never drift apart. This is also the only way to drive the plugin from a
keybind or a shell test without clicking the panel.

## Watchdog: mpv dying is not otherwise observable

Nothing tells the service when mpv dies (stream drop, network loss, external
kill) — `playing` would stay true forever and the next toggle would read as
"pause" instead of restarting. `update()` runs every `WATCHDOG_MS` (5s) and
checks the active tag with `noctalia.processMatches`; when the process is
gone it resets to idle and notifies. **It deliberately does not
auto-reconnect** — it only makes the reported state true again; the user
presses play.

Two guards in there are not optional:

- `LAUNCH_GRACE_MS` (3s) — mpv takes a moment to appear in `/proc`, so a
  launch younger than this is never judged, or the watchdog kills the state
  of a stream that is just starting.
- The callback re-checks `activeMark ~= mark` before acting. `processMatches`
  is async, so a play/pause/next can land while the check is in flight —
  same class of race as the `pkill` tag, and the same fix.

`noctalia.processMatches` matches against the **full command line**, not just
the process name — verified live against the `--title=` tag, which is the
only reason a per-launch tag is findable at all. If that ever changes, the
fallback is `runAsync({"pgrep","-f",mark}, cb)` (short-lived command, so the
callback form is correct *there* — but still never for the mpv launch).

## Surviving a script reload: adopt, don't orphan

A `.luau` edit destroys the service runtime but **not** the mpv process it
started. `noctalia.state` is process-lifetime and survives a service restart
(per the entries docs), so the active tag and `streamSeq` are mirrored there,
and `adoptOrSweep()` at load re-adopts the running process instead of losing
control of it. Without this, every edit left an unreachable mpv playing while
the plugin showed idle, and the next play started a second one in parallel.

The `else` branch matters just as much: empty state means a fresh Noctalia
start or a re-enable, where any surviving process is unreachable by
definition — so it gets swept with the broad `STREAM_MARK` `pkill`.

`onExit` therefore returns early on `reason == "reload"` (killing there would
drop playback on every edit) and sweeps on `disable` / `uninstall` /
`shutdown`, where nothing can control the process afterwards.

Related: `lastCommandSeq` is `nil` after a reload while the last command may
still sit in `state`. It is re-seeded from `noctalia.state.get("command")`
before the watch is registered, otherwise a re-fired watch replays that
command — a stale `next` would skip a station on every script edit.

## Verification status

Verified live on this host (log + `pgrep`, 2026-09-18): watchdog detects an
external kill (~5s) and does not false-positive on a healthy stream over
several ticks; adoption across a `touch`-triggered reload keeps the same mpv
PID and `streamSeq` continues correctly; the empty-state sweep; `disable`
kills mpv; re-enable comes up idle with no stale process; all `onIpc` events.

**Not verified:** `reason == "shutdown"` — testing it needs a full Noctalia
restart. It takes the identical code path as `disable` (both fall through the
`reload` guard into the same sweep), so the only unverified part is whether
Noctalia actually reports `"shutdown"` and still runs `onExit` during
teardown. If an mpv ever survives a Noctalia restart, this is the first place
to look.

## Why playback control lives in the service, not the panel

A `[[panel]]` entry's Luau VM unloads when the panel closes. Any subprocess a
panel script starts directly dies with it — the mpv process would play while
the panel was open and die within ~1s of closing it, MPRIS registering and
immediately unregistering, no error in the log at all. A `[[service]]` entry
stays loaded for as long as the plugin is enabled, independent of panel
open/close, so it's the only correct owner of a subprocess meant to outlive
one UI interaction. Panel and widget talk to the service only through
`noctalia.state` (command in, playing/stationName/currentIndex out) — never
call `noctalia.runAsync` from `panel.luau` for anything that must survive the
panel closing.

## Why every mpv launch gets a unique `--title` tag

`stopProcess()` kills the previous stream with `pkill -f <tag>` before
starting the next one. `pkill -f` runs asynchronously and scans `/proc`; if
that scan completes *after* the next mpv has already started, a **shared**
tag lets it match and kill the brand-new process instead of the old one —
reproduced directly in a terminal test (mpv started, `pkill -f` fired 50ms
later, the fresh process died). The fix: `streamSeq` increments on every
`playIndex()` call, `activeMark` holds the exact tag of the currently-running
instance, and `stopProcess()` only ever targets that one specific tag. A stale
`pkill -f <fixed-tag>` can never match a future process this way. Don't
revert to a fixed shared tag for the per-play kill; the generic
`STREAM_MARK`-only sweep in `onExit` (disable/uninstall) is fine precisely
*because* nothing new is launched afterward.

## `noctalia.runAsync` callback form has an implicit timeout — don't use it for mpv

`noctalia.runAsync(cmd, cb)` (the form that captures stdout/stderr/exitCode)
is built for short-lived commands and enforces a timeout — around mpv this
showed up as the stream dying at almost exactly 5s every time
(`result.timedOut == true`, `exitCode == 4`), which briefly reappeared while
debugging the race above. mpv is meant to run indefinitely, so its launch
**must** use the fire-and-forget form `noctalia.runAsync(cmd)` with no
callback. If you need to add capture/debug logging around the mpv launch
again, do it temporarily and revert to the callback-less form before calling
it done — don't ship the callback form for the actual playback launch.

## Pause/resume model

There is no real pause: "pause" stops the mpv process, "play" starts a fresh
one. This matches how live radio streams behave elsewhere (no seek position
to resume from) and is intentional, not a shortcut to fix later.

## Debugging checklist

- `noctalia msg plugin nyx/radio-player:radio-service all status` — logs
  `playing`, `currentIndex`, station and the active tag in one line. Fastest
  way to see what the service thinks is true.
- `pgrep -x mpv` plus reading `/proc/<pid>/cmdline` — is mpv actually running
  right now, and under which tag? Note: `pgrep -f noctalia-radio-player-stream`
  from an interactive shell also matches the shell running that very command
  (and `pkill -f` will kill your own terminal) — match on `title=` or use the
  `pgrep -x mpv` form instead.
- `~/.cache/noctalia/noctalia.log` — `noctalia.log(...)` calls show up as
  `[script-runtime]` lines; MPRIS registration (`org.mpris.MediaPlayer2.mpv`
  owner changes) is a reliable independent signal that mpv actually started
  and is still alive, since the widget/panel do not directly report mpv's
  process state.
- A `duplicate entry id` warning drops the WHOLE plugin, not just the
  offending entry — check that first if the plugin silently vanishes from
  the bar/settings after an edit.
- `noctalia msg plugins disable|enable nyx/radio-player` exercises the
  teardown and cold-start paths without restarting Noctalia.

