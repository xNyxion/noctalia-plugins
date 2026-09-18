-- Radio service: owns the mpv subprocess, the favorites store and the
-- radio-browser.info search. Source of truth for everything the widget and
-- panel display, published via noctalia.state.
--
-- Playback lives here, not in the panel: a [[panel]] entry's own Luau
-- runtime unloads when the panel closes, which killed any process the
-- panel spawned directly. A [[service]] entry stays loaded for as long as
-- the plugin is enabled, so mpv outlives panel open/close cycles.
--
-- Favorites live here too, for the same reason: the panel is not loaded
-- most of the time, and the bar widget must be able to step through them
-- without the panel ever having been opened.
--
-- PROCESS IDENTITY IS A PID, NOT A PATTERN. Every launch writes its PID to
-- a file in the plugin data dir, and both liveness and kill go through that
-- PID, cross-checked read-only against /proc/<pid>/cmdline. There is no
-- pkill/pgrep anywhere: a pattern broad enough to find our mpv also matches
-- the very shell running the check (suicide for pkill, always-true for
-- pgrep), and a shared pattern additionally races a freshly started
-- process. A PID cross-checked against /proc cannot do either.
--
-- The PID file also survives a script reload: a reload destroys this
-- runtime but not the running mpv, so adoptOrSweep() reads it back.

local dataDir = noctalia.pluginDataDir()
local PIDFILE = dataDir .. "/mpv.pid"
local FAVFILE = dataDir .. "/favorites.json"

local API_MIRRORS = {
  "https://de1.api.radio-browser.info",
  "https://de2.api.radio-browser.info",
  "https://fi1.api.radio-browser.info",
}
local UA = "nyx/radio-player/2.0"

local WATCHDOG_MS = 4000
-- mpv needs a few seconds to resolve DNS, connect and settle before it is
-- fair to judge it; and one missed observation is not death (poll races, a
-- slow server). Only DEAD_STREAK consecutive misses past the grace window
-- count as gone.
local LAUNCH_GRACE_MS = 8000
local DEAD_STREAK = 2

-- Curated metal stations, every one verified by actually decoding it with
-- mpv. Shipped as a browsable folder inside favorites rather than as the
-- station list itself -- the list proper is whatever the user saves.
local METAL_PRESETS = {
  { name = "Rock Antenne Heavy Metal", url = "http://mp3channels.webradio.rockantenne.de/heavy-metal" },
  { name = "RADIO BOB! Metal", url = "http://streams.radiobob.de/bob-metal/mp3-192/streams.radiobob.de/" },
  { name = "SomaFM Metal Detector", url = "https://ice5.somafm.com/metal-128-aac" },
  { name = "Pinguin Aardschok", url = "https://streams.pinguinradio.com/Aardschok192.mp3" },
  { name = "Radio ROKS Hard'n'Heavy", url = "http://online.radioroks.ua/RadioROKS_HardnHeavy_HD" },
  { name = "Big R 80s Metal", url = "http://bigrradio.cdnstream1.com/5186_128" },
  { name = "1.FM High Voltage", url = "http://strm112.1.fm/highvoltage_mobile_mp3" },
  { name = "181.FM Hard Rock", url = "https://listen.181fm.com/181-hardrock_128k.mp3" },
  { name = "Thrash Metal", url = "http://79.120.77.11:8000/thrashmetal" },
  { name = "Thrash Black Metal", url = "http://213.141.131.10:8004/thrashblack" },
  { name = "Melodic Death Metal", url = "http://79.120.77.11:8000/melodicdeath" },
  { name = "Brutal Death Metal", url = "http://79.111.119.111:8000/brutaldeathmetal" },
  { name = "Death Doom Metal", url = "http://79.120.39.202:9007/" },
  { name = "Funeral Doom Metal", url = "http://79.120.77.11:8000/funeraldoom" },
  { name = "Gothic Doom Metal", url = "http://79.120.39.202:8004/gothdoommet" },
  { name = "Depressive Black Metal", url = "http://79.111.119.111:9011/" },
  { name = "Gothic Black Metal", url = "http://79.120.39.202:8000/gothblackmet" },
  { name = "Power Metal", url = "http://79.120.77.11:9099/" },
  { name = "Melodic Power Metal", url = "http://79.111.119.111:8000/melodicpower" },
  { name = "Symphonic Power Metal", url = "http://213.141.131.10:8000/symphopower" },
  { name = "Melodic Metalcore", url = "http://79.111.14.76:8002/melodicmetalcore" },
  { name = "ChroniX Metalcore", url = "http://usa17.fastcast4u.com:5508/stream" },
}

local favorites = {}
local current = nil -- { id, name, url, codec, bitrate, country }
local playing = false
local volume = 85
local searchLimit = 25
local lastCommandSeq = nil
local lastLaunchMs = 0
local deadStreak = 0

local function clampVolume(v)
  v = tonumber(v)
  if v == nil then
    return volume
  end
  return math.max(0, math.min(100, math.floor(v)))
end

-- A station's identity: the radio-browser uuid when it has one, otherwise
-- the stream URL. Presets and hand-added stations have no uuid, so nothing
-- may assume one exists.
local function stationId(st)
  if type(st) ~= "table" then
    return nil
  end
  if type(st.id) == "string" and st.id ~= "" then
    return st.id
  end
  return st.url
end

local function loadConfig()
  volume = clampVolume(noctalia.getConfig("volume") or volume)
  local lim = tonumber(noctalia.getConfig("search_limit"))
  if lim ~= nil then
    searchLimit = math.max(5, math.min(50, math.floor(lim)))
  end
end

local function saveFavorites()
  -- An empty Luau table encodes as `{}` (a JSON object), not `[]`. It still
  -- round-trips through ipairs, but the file's type would flip with its
  -- content -- write the empty array literally so favorites.json is always
  -- a JSON array for anything else that reads it.
  if #favorites == 0 then
    noctalia.writeFile(FAVFILE, "[]\n")
    return
  end
  local encoded = noctalia.json.encode(favorites, true)
  if type(encoded) == "string" then
    noctalia.writeFile(FAVFILE, encoded)
  end
end

local function loadFavorites()
  favorites = {}
  local raw = noctalia.readFile(FAVFILE)
  if type(raw) ~= "string" or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  for _, f in ipairs(decoded) do
    if type(f) == "table" and type(f.url) == "string" and f.url ~= "" then
      table.insert(favorites, {
        id = f.id or f.url,
        name = f.name or f.url,
        url = f.url,
        codec = f.codec,
        bitrate = f.bitrate,
        country = f.country,
      })
    end
  end
end

local function publish()
  noctalia.state.set("playing", playing)
  noctalia.state.set("volume", volume)
  noctalia.state.set("favorites", favorites)
  noctalia.state.set("presets", METAL_PRESETS)
  noctalia.state.set("stationName", current and current.name or nil)
  noctalia.state.set("currentId", current and stationId(current) or "")
  noctalia.state.set("currentUrl", current and current.url or "")
end

-- Reads the recorded PID, or nil. Never trusts the file blindly: a stale
-- PID can have been recycled by an unrelated process.
local function readPid()
  local raw = noctalia.readFile(PIDFILE)
  if type(raw) ~= "string" then
    return nil
  end
  local pid = tonumber(noctalia.string.trim(raw))
  if pid == nil or pid < 1 or pid ~= math.floor(pid) then
    return nil
  end
  return math.floor(pid)
end

-- Liveness: the PID exists AND its cmdline still says mpv. Read-only, so it
-- can never signal anything. Answers through the callback.
local function isAlive(pid, onResult)
  if pid == nil then
    onResult(false)
    return
  end
  noctalia.readFileAsync("/proc/" .. tostring(pid) .. "/cmdline", function(contents)
    onResult(type(contents) == "string" and string.find(contents, "mpv", 1, true) ~= nil)
  end)
end

-- Kill by PID, guarded by the same /proc cross-check, so a recycled PID is
-- never signalled. Detached on purpose: it must also work from onExit,
-- after this runtime is gone.
local function stopProcess()
  local pid = readPid()
  noctalia.removeFile(PIDFILE)
  if pid == nil then
    return
  end
  local p = tostring(pid)
  noctalia.runAsync(
    "if grep -qa mpv /proc/" .. p .. "/cmdline 2>/dev/null; then "
      .. "kill " .. p .. " 2>/dev/null; sleep 0.5; "
      .. "kill -9 " .. p .. " 2>/dev/null; fi"
  )
end

local function shellQuote(s)
  return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
end

local function playStation(st)
  if type(st) ~= "table" or type(st.url) ~= "string" or st.url == "" then
    noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("notify.no_url"))
    return
  end
  stopProcess()
  -- Fire-and-forget: runAsync(cmd, cb) enforces a timeout meant for short
  -- commands and kills mpv at ~5s. Do not add a callback.
  --
  -- "--" ends option parsing: stream URLs come from the API or from user
  -- input, and without it a URL starting with "-" is read as an mpv option.
  -- String form (not the argument array) because recording $! needs a
  -- shell; every interpolated value goes through shellQuote.
  local cmd = "mpv --no-video --really-quiet --volume=" .. tostring(volume)
    .. " -- " .. shellQuote(st.url) .. " >/dev/null 2>&1 & echo $! > " .. shellQuote(PIDFILE)
  local ok = noctalia.runAsync(cmd)
  if not ok then
    noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("notify.mpv_missing"))
    return
  end
  current = {
    id = stationId(st),
    name = st.name or st.url,
    url = st.url,
    codec = st.codec,
    bitrate = st.bitrate,
    country = st.country,
  }
  lastLaunchMs = noctalia.nowMs()
  deadStreak = 0
  playing = true
  publish()
end

local function stop()
  stopProcess()
  playing = false
  publish()
end

local function togglePlay()
  if playing then
    stop()
  elseif current then
    playStation(current)
  elseif #favorites > 0 then
    playStation(favorites[1])
  elseif #METAL_PRESETS > 0 then
    playStation(METAL_PRESETS[1])
  end
end

-- Volume has no live control path: mpv is launched with --volume and there
-- is no IPC socket, so a change while playing restarts the stream. Live
-- radio has no seek position, so a restart loses nothing but a second of
-- audio -- same reasoning as the stop/play model.
local function setVolume(v)
  local next = clampVolume(v)
  if next == volume then
    return
  end
  volume = next
  if playing and current then
    playStation(current)
  else
    publish()
  end
end

local function findFavorite(id)
  for i, f in ipairs(favorites) do
    if stationId(f) == id then
      return i
    end
  end
  return nil
end

local function toggleFavorite(st)
  local id = stationId(st)
  if id == nil then
    return
  end
  local at = findFavorite(id)
  if at then
    table.remove(favorites, at)
  else
    table.insert(favorites, {
      id = id,
      name = st.name or st.url,
      url = st.url,
      codec = st.codec,
      bitrate = st.bitrate,
      country = st.country,
    })
  end
  saveFavorites()
  publish()
end

-- Search runs against radio-browser.info, walking mirrors on failure (de1 is
-- sometimes down). Results are published as state, never returned: the panel
-- may be re-rendered or reloaded between request and response.
local function search(query, attempt)
  attempt = attempt or 1
  query = noctalia.string.trim(tostring(query or ""))
  if query == "" then
    noctalia.state.set("searchResults", {})
    noctalia.state.set("searchState", "idle")
    return
  end
  local base = API_MIRRORS[attempt]
  if base == nil then
    noctalia.state.set("searchState", "error")
    return
  end
  noctalia.state.set("searchState", "loading")
  local url = base .. "/json/stations/search?name=" .. noctalia.string.urlEncode(query)
    .. "&limit=" .. tostring(searchLimit) .. "&hidebroken=true&order=votes&reverse=true"
  noctalia.http({ url = url, headers = { "User-Agent: " .. UA } }, function(res)
    if not res.ok then
      search(query, attempt + 1)
      return
    end
    local data = noctalia.json.decode(res.body)
    if type(data) ~= "table" then
      search(query, attempt + 1)
      return
    end
    local out = {}
    for _, s in ipairs(data) do
      local u = s.url_resolved
      if type(u) ~= "string" or u == "" then
        u = s.url
      end
      if type(u) == "string" and u ~= "" then
        table.insert(out, {
          id = s.stationuuid or u,
          name = s.name and noctalia.string.trim(s.name) or u,
          url = u,
          codec = s.codec,
          bitrate = s.bitrate,
          country = s.country,
        })
      end
    end
    noctalia.state.set("searchResults", out)
    noctalia.state.set("searchState", #out == 0 and "empty" or "done")
  end)
end

-- Step through favorites; used by the bar widget's scroll gesture. Falls
-- back to the presets when nothing has been saved yet, so scrolling is
-- never a dead gesture on a fresh install.
local function stepStation(delta)
  local list = #favorites > 0 and favorites or METAL_PRESETS
  if #list == 0 then
    return
  end
  local at = nil
  local id = current and stationId(current) or nil
  if id then
    for i, s in ipairs(list) do
      if stationId(s) == id then
        at = i
        break
      end
    end
  end
  local nextAt
  if at == nil then
    nextAt = 1
  else
    nextAt = ((at - 1 + delta) % #list) + 1
  end
  playStation(list[nextAt])
end

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.type == "play" then
    playStation(cmd.station)
  elseif cmd.type == "stop" then
    stop()
  elseif cmd.type == "toggle" then
    togglePlay()
  elseif cmd.type == "volume" then
    setVolume(cmd.volume)
  elseif cmd.type == "favorite" then
    toggleFavorite(cmd.station)
  elseif cmd.type == "search" then
    search(cmd.query)
  elseif cmd.type == "step" then
    stepStation(cmd.delta or 1)
  end
end

-- Called once at load. A reload leaves the previous runtime's mpv running
-- and its PID file on disk, so re-adopt that process instead of orphaning
-- it. A PID file with no live mpv behind it is stale -- drop it.
local function adoptOrSweep()
  local pid = readPid()
  if pid == nil then
    playing = false
    publish()
    return
  end
  -- noctalia.state survives a reload, so the station being played is still
  -- described there even though this runtime's locals started empty.
  local id = noctalia.state.get("currentId")
  local name = noctalia.state.get("stationName")
  local url = noctalia.state.get("currentUrl")
  if type(id) == "string" and id ~= "" then
    local at = findFavorite(id)
    if at then
      current = favorites[at]
    elseif type(url) == "string" and url ~= "" then
      current = { id = id, name = type(name) == "string" and name or url, url = url }
    end
  end

  isAlive(pid, function(alive)
    if alive then
      lastLaunchMs = noctalia.nowMs()
      deadStreak = 0
      playing = true
      noctalia.log("radio-player service: adopted running mpv pid=" .. tostring(pid))
    else
      playing = false
      noctalia.removeFile(PIDFILE)
      noctalia.log("radio-player service: stale pid " .. tostring(pid) .. ", no mpv; dropped")
    end
    publish()
  end)
end

loadConfig()
loadFavorites()
adoptOrSweep()

-- A reload resets lastCommandSeq to nil while the last command may still
-- sit in state. Seed it, or a re-fired watch would execute that command a
-- second time (a stale play would restart the stream on every script edit).
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
  if not playing then
    return
  end
  if noctalia.nowMs() - lastLaunchMs < LAUNCH_GRACE_MS then
    return
  end
  local pid = readPid()
  isAlive(pid, function(alive)
    -- The check is async: a play/stop may have landed while it ran.
    if not playing then
      return
    end
    if alive then
      deadStreak = 0
      return
    end
    deadStreak = deadStreak + 1
    if deadStreak < DEAD_STREAK then
      return
    end
    deadStreak = 0
    local failedFast = noctalia.nowMs() - lastLaunchMs < 30000
    local name = current and current.name or "?"
    playing = false
    noctalia.removeFile(PIDFILE)
    publish()
    if failedFast then
      noctalia.log("radio-player service: mpv died shortly after launch for " .. name)
      noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("notify.stream_failed", { name = name }))
    else
      noctalia.log("radio-player service: mpv went away during playback of " .. name)
      noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("notify.stream_ended"))
    end
  end)
end

function onConfigChanged()
  local before = volume
  loadConfig()
  publish()
  if playing and current and volume ~= before then
    playStation(current)
  end
end

-- External control surface, for keybinds and scripts:
--   noctalia msg plugin nyx/radio-player:radio-service all toggle
--   noctalia msg plugin nyx/radio-player:radio-service all volume 70
--   noctalia msg plugin nyx/radio-player:radio-service all search "lofi"
-- A service has no output, so `all` is the only target that matches it.
function onIpc(event, payload)
  if event == "toggle" then
    togglePlay()
  elseif event == "stop" then
    stop()
  elseif event == "play" then
    -- Payload is an index into favorites (or the presets while no favorite
    -- has been saved); empty resumes the current station.
    local idx = tonumber(payload)
    local list = #favorites > 0 and favorites or METAL_PRESETS
    if idx and list[idx] then
      playStation(list[idx])
    elseif current then
      playStation(current)
    end
  elseif event == "next" then
    stepStation(1)
  elseif event == "prev" then
    stepStation(-1)
  elseif event == "volume" then
    setVolume(tonumber(payload))
  elseif event == "volume-up" then
    setVolume(volume + 5)
  elseif event == "volume-down" then
    setVolume(volume - 5)
  elseif event == "search" then
    search(tostring(payload or ""))
  elseif event == "favorite" then
    -- Star/unstar the station that is currently loaded. Without a payload
    -- this is the only station the service can name with certainty.
    if current then
      toggleFavorite(current)
    end
  elseif event == "status" then
    -- Read-only probe; shows up in the log rather than as a return value.
    noctalia.log(string.format(
      "radio-player service: playing=%s station=%s volume=%d favorites=%d pid=%s",
      tostring(playing),
      tostring(current and current.name),
      volume,
      #favorites,
      tostring(readPid())
    ))
  else
    noctalia.log("radio-player service: unknown ipc event " .. tostring(event))
  end
end

function onExit(_signal, reason)
  if reason == "reload" then
    -- Script reload only: this runtime goes away, mpv does not. The PID file
    -- stays on disk and the next load re-adopts the process. Killing here
    -- would drop playback on every edit.
    return
  end
  -- disable / uninstall / shutdown: nothing can control the process after
  -- this. stopProcess detaches its kill, so it still completes once this
  -- runtime is gone.
  stopProcess()
  playing = false
end
