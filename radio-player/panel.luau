-- Player panel: pure UI over the radio service's shared state.
--
-- Sends commands via noctalia.state.set("command", {...}); the
-- `nyx/radio-player:player` service (service.luau) owns the mpv
-- subprocess and executes them. This script never calls
-- noctalia.runAsync for mpv itself -- a panel's own Luau runtime
-- unloads when the panel closes, which would kill any process it
-- spawned directly.

local stations = {}

local function loadStations()
  stations = {}
  local raw = noctalia.getConfig("stations") or {}
  for _, entry in ipairs(raw) do
    local sep = string.find(entry, "|", 1, true)
    if sep then
      table.insert(stations, {
        name = noctalia.string.trim(string.sub(entry, 1, sep - 1)),
      })
    end
  end
end

local function sendCommand(cmd)
  cmd.seq = noctalia.nowMs()
  noctalia.log("radio-player panel: sending command type=" .. tostring(cmd.type) .. " seq=" .. tostring(cmd.seq))
  noctalia.state.set("command", cmd)
end

local function currentIndex()
  local idx = noctalia.state.get("currentIndex")
  if type(idx) ~= "number" or idx < 1 or idx > #stations then
    idx = 1
  end
  return idx
end

local function isPlaying()
  return noctalia.state.get("playing") == true
end

local function render()
  local idx = currentIndex()
  local rows = {}
  for i, st in ipairs(stations) do
    table.insert(rows, ui.button({
      key = "station-" .. i,
      text = st.name,
      variant = (i == idx and isPlaying()) and "primary" or "ghost",
      contentAlign = "start",
      onClick = function() sendCommand({ type = "play", index = i }) end,
    }))
  end

  local nowPlaying = isPlaying() and noctalia.state.get("stationName") or noctalia.tr("panel.idle")

  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onClosePanel" }),
    }),
    ui.label({ text = nowPlaying, color = "primary", maxLines = 1 }),
    ui.row({ gap = 8, justify = "center" }, {
      ui.button({ glyph = "player-skip-back", controlSize = "lg", onClick = "onPrev" }),
      ui.button({
        glyph = isPlaying() and "player-pause" or "player-play",
        controlSize = "lg",
        variant = "primary",
        onClick = "onTogglePlay",
      }),
      ui.button({ glyph = "player-skip-forward", controlSize = "lg", onClick = "onNext" }),
    }),
    ui.separator({}),
    ui.scroll({ gap = 4, flexGrow = 1 }, rows),
  }))
end

noctalia.state.watch("playing", function(_) render() end)
noctalia.state.watch("currentIndex", function(_) render() end)
noctalia.state.watch("stationName", function(_) render() end)

function onOpen(_context)
  loadStations()
  render()
end

function onNext() sendCommand({ type = "next" }) end
function onPrev() sendCommand({ type = "prev" }) end
function onTogglePlay() sendCommand({ type = "toggle" }) end
function onClosePanel() panel.close() end
