# AGENTS.md — nyx/radio-player

Noctalia v5 plugin: bar widget + browser panel for internet radio. Stations
come from radio-browser.info search, favorites are saved to disk, and a
curated metal folder ships with the plugin. Playback via `mpv`.

Read this before touching process management, state sharing or the favorites
store — the current shape exists because several non-obvious bugs were found
and fixed here, and each section below says which.

## Files

- `plugin.toml` — manifest. One `[[widget]]` (`id="widget"`), one
  `[[service]]` (`id="radio-service"`), one `[[panel]]` (`id="player"`).
  **Entry ids must be unique across the WHOLE plugin, not just within one
  entry kind** — reusing `"player"` for both the service and the panel made
  Noctalia silently drop the entire plugin (`duplicate entry id 'player'` in
  the log, not a partial failure).
- `service.luau` — **owns the mpv subprocess, the favorites file and the
  API search.** Source of truth for everything the UI shows, published via
  `noctalia.state`. Listens on `noctalia.state.watch("command", ...)`, runs
  the watchdog in `update()`, and accepts external control through `onIpc`.
- `panel.luau` — **pure UI, no process control.** Three views in one panel
  (`home` / `folder` / `search`), view state local and reset on open.
- `widget.luau` — bar capsule; left-click opens the panel, right-click
  toggles playback, scroll steps through favorites.
- `translations/en.json` — all label/tooltip/notify strings.

Runtime data lives in `noctalia.pluginDataDir()`
(`~/.local/state/noctalia/plugins/data/nyx/radio-player/`): `favorites.json`
and `mpv.pid`. Both can be deleted safely.

## Favorites are not a setting

They live in `favorites.json`, owned by the service, not in a `string_list`
setting. A setting is written by the settings GUI, so the star button could
not write it back, and a flat string list cannot carry uuid/codec/bitrate.

They live in the SERVICE, not the panel (which is where `fel/radio` keeps
them): the panel is unloaded most of the time, and the bar widget must be
able to step through favorites on scroll without the panel ever having been
opened.

Empty-list gotcha: an empty Luau table encodes as `{}`, a JSON *object*, so
`saveFavorites()` writes the `[]` literal explicitly. Reading `{}` back
happens to work (`ipairs` yields nothing) but the file's type would flip with
its content.

## Process identity is a PID, not a pattern

Every launch writes its PID to `mpv.pid`; liveness and kill both go through
that PID, cross-checked read-only against `/proc/<pid>/cmdline`. There is no
`pkill`/`pgrep` anywhere, for two independent reasons:

- A pattern broad enough to find our mpv also matches the shell running the
  check — suicide for `pkill`, always-true for `pgrep`. This is not
  theoretical: a `pkill -f noctalia-radio-player-stream` typed in a terminal
  during testing killed that terminal.
- A shared pattern races a freshly started process: `pkill -f` scans `/proc`
  asynchronously and can complete *after* the next mpv started, killing the
  new one. (The earlier fix was a unique per-launch `--title` tag; PID
  bookkeeping removes the problem instead of working around it.)

The `/proc` cross-check before `kill` is what makes a stale PID harmless — a
recycled PID belonging to an unrelated process is never signalled.

## Surviving a script reload: adopt, don't orphan

A `.luau` edit destroys the service runtime but **not** the mpv it started.
`mpv.pid` stays on disk and `noctalia.state` survives a service restart (it
is process-lifetime, per the entries docs), so `adoptOrSweep()` re-adopts the
running process and restores which station it is playing from `currentId` /
`currentUrl` / `stationName`. Without this, every edit left an unreachable
mpv playing while the plugin showed idle, and the next play started a second
one in parallel.

`onExit` therefore returns early on `reason == "reload"` — killing there
would drop playback on every edit — and calls `stopProcess()` on `disable` /
`uninstall` / `shutdown`, where nothing can control the process afterwards.
The kill is detached (`runAsync` without a callback), so it completes after
the runtime is gone.

Related: `lastCommandSeq` is `nil` after a reload while the last command may
still sit in `state`. It is re-seeded from `noctalia.state.get("command")`
before the watch is registered, otherwise a re-fired watch replays that
command.

## Watchdog: mpv dying is not otherwise observable

Nothing tells the service when mpv dies (stream drop, network loss, external
kill) — `playing` would stay true forever. `update()` runs every
`WATCHDOG_MS` (4s) and checks the recorded PID. **It deliberately does not
auto-reconnect**; it only makes the reported state true again.

Three guards, none optional:

- `LAUNCH_GRACE_MS` (8s) — mpv needs time to resolve DNS and connect; a
  younger launch is never judged.
- `DEAD_STREAK` (2) — one missed observation is not death (poll races, a slow
  server). Only two consecutive misses count. Borrowed from `fel/radio`.
- The callback re-checks `playing` before acting, because the `/proc` read is
  async and a play/stop can land while it is in flight.

A launch that dies within 30s is reported as a failed stream
(`notify.stream_failed`), a later death as an ended one — the first usually
means a dead URL, the second a dropped connection.

## `noctalia.runAsync` callback form has an implicit timeout

`runAsync(cmd, cb)` (the form capturing stdout/stderr/exitCode) is built for
short-lived commands and enforces a timeout — around mpv this killed the
stream at almost exactly 5s every time (`timedOut == true`, `exitCode == 4`).
The mpv launch **must** use the callback-less form. Debug logging around the
launch is fine temporarily; revert it before calling anything done.

`--` before the URL ends mpv's option parsing. Verified locally: without it,
`mpv --no-video "--vo=null"` consumes the argument as an option; with it, mpv
treats it as a file. Stream URLs come from the API and from user input, so
this is a real input path, and the argument-array form of `runAsync` does not
help — it prevents *shell* injection, not mpv's own parsing.

## Volume restarts the stream, on purpose

mpv is launched with `--volume` and there is no IPC socket (`fel/radio` uses
`socat` for this; we don't depend on it). Changing volume while playing
relaunches mpv. Live radio has no seek position, so a restart costs about a
second of audio and nothing else — same reasoning as stop/play instead of a
real pause.

The panel's slider therefore commits on `onDragEnd`, not `onChange`; reacting
to every intermediate position would restart the stream repeatedly. `ui.slider`
is value-driven (unlike `ui.input`), so the current volume must be passed on
every render or it snaps back.

On this Noctalia build the slider's callback args did not match the docs:
`onChange`'s value arrived as a string (`tonumber()` before `math.floor()`),
and `onDragEnd` fired with no value argument at all — `v` is `nil`, so it
falls back to whatever `onChange` last recorded in `pendingVolume`. Both are
guarded in `panel.luau`; if a future Noctalia fixes the argument shape this
code still works, it just never hits the nil branch.

## Volume slider is perceptual, not linear amplitude

`mpv --volume` is a CUBIC gain curve, not linear amplitude and not perceived
loudness either — roughly `dB = 60*log10(v/100)`. 20% amplitude is already
about a 42dB cut (measured directly against mpv's own PCM output, not
assumed), close to silent — passing the slider value straight through made
the bottom third of the range useless. `service.luau`'s `volumeToMpv()`
applies `sqrt(slider/100) * 100` before the `--volume=` flag: slider 20 →
mpv ~45 (~-21dB), slider 50 → mpv ~71 (~-9dB), slider 100 → mpv 100 (both
ends pinned). Net effect against the real cubic law is close to
`30*log10(slider)`, a normal perceptual taper.

The STORED/SHOWN/SAVED volume (setting, `noctalia.state`, the slider position
itself) is always the raw 0-100 slider value — the curve applies only at the
mpv launch command. Anything that reads `volume` from state or config gets the
slider number, not the mpv number; only `playStation()` converts.

Retuning: change the exponent in `volumeToMpv`, don't re-derive from an
assumed (rather than measured) mpv gain law — the linear assumption this fix
replaced was wrong by nearly 30dB at the low end.

**Known gap, not addressed here:** volume is not persisted anywhere.
`loadConfig()` only reads the `volume` SETTING (manifest default 85);
`setVolume()` never writes a file the way `saveFavorites()` does. It resets
to the setting default on every Noctalia restart even though the user last
had it elsewhere. Fixing this means mirroring `favorites.json`'s pattern: a
small file in `pluginDataDir()`, written on every `setVolume()`, read in
`loadConfig()` before falling back to the setting.

## No next/prev transport

A radio stream has no tracks to skip. The panel's only transport control is
play/stop; stations are picked from a list. The bar widget's scroll gesture
still steps through favorites (falling back to the presets while nothing is
saved, so scrolling is never dead on a fresh install).

## External control (`onIpc`)

`noctalia msg plugin nyx/radio-player:radio-service all <event>`:
`toggle`, `stop`, `play [index]`, `next`, `prev`, `volume <0-100>`,
`volume-up`, `volume-down`, `search <text>`, `favorite` (stars/unstars the
loaded station), `status` (logs current state).

A service has no output, so `all` is the only target that reaches it —
`focused` silently matches nothing.

## Verification status

Verified live on this host (log + `pgrep` + `/proc`, 2026-09-18, v2.0.0):
cold start with no favorites; play from presets; volume change restarts mpv
at the new level with exactly one process; favorite/unfavorite writes
`favorites.json` and survives disable/enable; search returns results from
mirror 1 and an empty query issues no request; scroll-step uses favorites;
watchdog detects an external kill and does not false-positive on a healthy
stream; adoption across a reload keeps the same mpv PID; `disable` kills mpv
and removes the PID file; toggle stops cleanly; no `[ERR]` and no
`undeclared setting` warnings.

Every shipped preset URL was verified by actually decoding it with mpv (real
codec reported, several seconds of playback) — not by trusting the directory
listing. Bitrates in the directory are frequently wrong; four "320 kbps"
Caprice entries decoded at ~48 kbps and were replaced with genuine 320s.

**Not verified:** `reason == "shutdown"` — testing it needs a full Noctalia
restart. It takes the identical path as `disable`, so the only open question
is whether Noctalia reports `"shutdown"` and still runs `onExit` during
teardown. If an mpv ever survives a Noctalia restart, look here first.

v2.0.1: fixed the volume slider (`onDragEnd`/`onChange` callback arg shapes
didn't match the runtime-api docs — string/nil, not number — see "Volume
restarts the stream, on purpose" above) and the volume curve (mpv's
`--volume` is cubic, not linear — see "Volume slider is perceptual, not
linear amplitude"). Verified live via IPC (`volume <N>`) + `/proc/<pid>/cmdline`
showing the converted mpv value at several slider positions, and via the log
showing hot-reload with no new `[ERR]`. Hands-on mouse drag confirmed working
by the user post-merge: stream pauses briefly (the documented restart cost)
and resumes at the new, correctly-curved level.

## Debugging checklist

- `noctalia msg plugin nyx/radio-player:radio-service all status` — logs
  playing/station/volume/favorites/pid in one line. Fastest truth check.
- `pgrep -x mpv` plus reading `/proc/<pid>/cmdline`. Do NOT use
  `pgrep -f <our-pattern>` interactively: it matches the shell running the
  command, and `pkill -f` will kill your own terminal.
- `~/.cache/noctalia/noctalia.log` — `noctalia.log(...)` shows up as
  `[script-runtime]`. `[plugin-bindings] ... read undeclared setting` means
  the manifest changed but was not reloaded: a source update alone does not
  apply manifest changes, `disable`+`enable` does.
- `noctalia msg plugins update nyx-plugins` picks up `.luau` edits from the
  path source; `catalog.toml` must carry the same version as `plugin.toml`
  or the store keeps showing the old one.
- A `duplicate entry id` warning drops the WHOLE plugin — check that first
  if the plugin silently vanishes after an edit.
- Search results and favorites are only visible through the panel or a
  temporary `noctalia.log` in the service; `noctalia.state` cannot be read
  from the shell.
