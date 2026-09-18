-- Radio service: owns the mpv subprocess and is the source of truth for
-- playback state (currentIndex, playing, stationName), published via
-- noctalia.state for the widget and panel to read.
--
-- Playback lives here, not in the panel: a [[panel]] entry's own Luau
-- runtime unloads when the panel closes, which killed any process the
-- panel spawned directly. A [[service]] entry stays loaded for as long
-- as the plugin is enabled, so mpv outlives panel open/close cycles.
--
-- Each launch gets a unique --title tag (STREAM_MARK .. "-" .. an
-- incrementing id), not a fixed shared one. `pkill -f` runs async and
-- can still be scanning /proc after the next mpv has already started;
-- with a shared tag it can match and kill that brand new process. A
-- unique-per-launch tag means the pkill for the OLD tag can never match
-- a NEW process, no matter how the two launches interleave.
--
-- A script reload destroys this runtime but NOT the mpv process it
-- started. noctalia.state is process-lifetime and survives that, so the
-- active tag and the launch counter are mirrored there and re-adopted on
-- load -- see adoptOrSweep().

local STREAM_MARK = "noctalia-radio-player-stream"
local WATCHDOG_MS = 5000
-- mpv needs a moment to show up in /proc; don't let the watchdog judge a
-- launch younger than this.
local LAUNCH_GRACE_MS = 3000

local stations = {}
local currentIndex = 1
local playing = false
local lastCommandSeq = nil
local streamSeq = 0
local activeMark = nil
local lastLaunchMs = 0

-- noctalia.state carries plain values; "" means "no active mark" rather
-- than relying on nil round-tripping through the channel.
local function setActiveMark(mark)
  activeMark = mark
  noctalia.state.set("activeMark", mark or "")
end

local function loadStations()
  stations = {}
  local raw = noctalia.getConfig("stations") or {}
  for _, entry in ipairs(raw) do
    local sep = string.find(entry, "|", 1, true)
    if sep then
      table.insert(stations, {
        name = noctalia.string.trim(string.sub(entry, 1, sep - 1)),
        url = noctalia.string.trim(string.sub(entry, sep + 1)),
      })
    end
  end
  if currentIndex > #stations then
    currentIndex = 1
  end
end

local function publish()
  noctalia.state.set("currentIndex", currentIndex)
  noctalia.state.set("playing", playing)
  noctalia.state.set("stationName", stations[currentIndex] and stations[currentIndex].name or nil)
end

local function stopProcess()
  if activeMark then
    noctalia.runAsync({ "pkill", "-f", activeMark })
    setActiveMark(nil)
  end
end

local function playIndex(i)
  if #stations == 0 then
    noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("notify.no_stations"))
    return
  end
  i = ((i - 1) % #stations) + 1
  stopProcess()
  streamSeq = streamSeq + 1
  noctalia.state.set("streamSeq", streamSeq)
  local mark = STREAM_MARK .. "-" .. tostring(streamSeq)
  local st = stations[i]
  -- Fire-and-forget form on purpose: runAsync(cmd, cb) enforces a timeout
  -- meant for short commands and kills mpv at ~5s. Do not add a callback.
  local ok = noctalia.runAsync({ "mpv", "--no-video", "--really-quiet", "--title=" .. mark, st.url })
  if not ok then
    noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("notify.mpv_missing"))
    return
  end
  setActiveMark(mark)
  lastLaunchMs = noctalia.nowMs()
  currentIndex = i
  playing = true
  publish()
end

local function pause()
  stopProcess()
  playing = false
  publish()
end

local function togglePlay()
  if playing then
    pause()
  else
    playIndex(currentIndex)
  end
end

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.type == "play" then
    playIndex(cmd.index or currentIndex)
  elseif cmd.type == "toggle" then
    togglePlay()
  elseif cmd.type == "next" then
    playIndex(currentIndex + 1)
  elseif cmd.type == "prev" then
    playIndex(currentIndex - 1)
  end
end

-- Called once at load. A reload leaves the previous runtime's mpv running;
-- noctalia.state is process-lifetime and still holds its tag, so re-adopt
-- it instead of orphaning it. An empty state means a fresh Noctalia start
-- or a re-enable -- a stale process may exist that nothing can control any
-- more, so sweep it.
local function adoptOrSweep()
  local seq = noctalia.state.get("streamSeq")
  if type(seq) == "number" and seq > streamSeq then
    streamSeq = seq
  end

  local mark = noctalia.state.get("activeMark")
  if type(mark) ~= "string" or mark == "" then
    noctalia.runAsync({ "pkill", "-f", STREAM_MARK })
    setActiveMark(nil)
    playing = false
    publish()
    return
  end

  local idx = noctalia.state.get("currentIndex")
  if type(idx) == "number" and idx >= 1 and idx <= #stations then
    currentIndex = idx
  end

  noctalia.processMatches(function(matched)
    if matched then
      setActiveMark(mark)
      lastLaunchMs = noctalia.nowMs()
      playing = true
      noctalia.log("radio-player service: adopted running stream " .. mark)
    else
      setActiveMark(nil)
      playing = false
      noctalia.log("radio-player service: stale mark " .. mark .. ", no process; sweeping")
      noctalia.runAsync({ "pkill", "-f", STREAM_MARK })
    end
    publish()
  end, mark)
end

loadStations()
adoptOrSweep()

-- A reload resets lastCommandSeq to nil while the last command may still
-- sit in state. Seed it, or a re-fired watch would execute that command a
-- second time (a stale "next" would skip a station on every script edit).
local existingCmd = noctalia.state.get("command")
if type(existingCmd) == "table" then
  lastCommandSeq = existingCmd.seq
end

noctalia.state.watch("command", function(cmd)
  if type(cmd) ~= "table" or cmd.seq == lastCommandSeq then
    return
  end
  lastCommandSeq = cmd.seq
  handleCommand(cmd)
end)

-- Watchdog: mpv can die without anyone telling us (stream drops, the user
-- kills it, the network goes away). Nothing else corrects `playing`, so
-- poll the process and fall back to idle when it is gone. This does NOT
-- auto-reconnect by design -- it only makes the reported state true again.
noctalia.setUpdateInterval(WATCHDOG_MS)

function update()
  if not playing or activeMark == nil then
    return
  end
  if noctalia.nowMs() - lastLaunchMs < LAUNCH_GRACE_MS then
    return
  end
  local mark = activeMark
  noctalia.processMatches(function(matched)
    if matched then
      return
    end
    -- The check is async: a play/pause/next may have landed while it ran.
    -- Only act if the mark we asked about is still the active one -- same
    -- reason the pkill uses a per-launch tag.
    if activeMark ~= mark or not playing then
      return
    end
    setActiveMark(nil)
    playing = false
    publish()
    noctalia.log("radio-player service: stream " .. mark .. " vanished; back to idle")
    noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("notify.stream_ended"))
  end, mark)
end

function onConfigChanged()
  -- Settings changed (e.g. the station list was edited). Refresh the
  -- list without interrupting whatever is currently playing.
  loadStations()
  publish()
end

-- External control surface, for keybinds and scripts:
--   noctalia msg plugin nyx/radio-player:radio-service all toggle
--   noctalia msg plugin nyx/radio-player:radio-service all play 2
-- A service has no output, so `all` is the only target that matches it.
-- Goes through handleCommand, so IPC and the panel share one code path.
function onIpc(event, payload)
  if event == "play" then
    local idx = tonumber(payload)
    handleCommand({ type = "play", index = idx or currentIndex })
  elseif event == "toggle" or event == "next" or event == "prev" then
    handleCommand({ type = event })
  elseif event == "pause" then
    pause()
  elseif event == "status" then
    -- Read-only probe; shows up in the log rather than as a return value.
    noctalia.log(string.format(
      "radio-player service: playing=%s index=%d station=%s mark=%s",
      tostring(playing),
      currentIndex,
      tostring(stations[currentIndex] and stations[currentIndex].name),
      tostring(activeMark)
    ))
  else
    noctalia.log("radio-player service: unknown ipc event " .. tostring(event))
  end
end

function onExit(_signal, reason)
  if reason == "reload" then
    -- Script reload only: this runtime goes away, mpv does not. The tag and
    -- counter live on in noctalia.state, and the next load re-adopts the
    -- process. Killing here would drop playback on every edit.
    return
  end
  -- disable / uninstall / shutdown: nothing can control the process after
  -- this, so sweep every launch this plugin ever started -- not just
  -- activeMark, which may be stale. Safe as a broad sweep precisely because
  -- nothing new gets launched afterwards.
  noctalia.runAsync({ "pkill", "-f", STREAM_MARK })
  playing = false
  setActiveMark(nil)
end
