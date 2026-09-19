-- Browser panel: pure UI over the radio service's shared state.
--
-- Sends commands via noctalia.state.set("command", {...}); the
-- `nyx/radio-player:radio-service` service owns the mpv subprocess, the
-- favorites file and the radio-browser.info search. This script never calls
-- noctalia.runAsync for mpv itself -- a panel's own Luau runtime unloads
-- when the panel closes, which would kill any process it spawned directly.
--
-- Three views, one panel: "home" lists favorites plus the Metal folder card,
-- "folder" shows the curated presets as tiles, "search" shows API results.
-- View state is local and resets to home on open; nothing here is persisted.
--
-- There is no next/prev transport: a radio stream has no tracks to skip, so
-- the only transport control is play/stop and stations are picked from a
-- list. (The bar widget still steps through favorites on scroll.)

local open = false
local view = "home" -- home | folder | search
local query = ""
-- Local echo of the slider position. The service only learns about a volume
-- change on drag end (each one restarts mpv), so the label needs a value to
-- show while the user is still dragging.
local pendingVolume = nil

local function sendCommand(cmd)
  cmd.seq = noctalia.nowMs()
  noctalia.state.set("command", cmd)
end

local function listOf(key)
  local v = noctalia.state.get(key)
  return type(v) == "table" and v or {}
end

local function isPlaying()
  return noctalia.state.get("playing") == true
end

local function currentId()
  local id = noctalia.state.get("currentId")
  return type(id) == "string" and id or ""
end

local function stationId(st)
  if type(st.id) == "string" and st.id ~= "" then
    return st.id
  end
  return st.url
end

local function isFavorite(st)
  local id = stationId(st)
  for _, f in ipairs(listOf("favorites")) do
    if stationId(f) == id then
      return true
    end
  end
  return false
end

local function currentVolume()
  if pendingVolume ~= nil then
    return pendingVolume
  end
  local v = noctalia.state.get("volume")
  if type(v) ~= "number" then
    return 85
  end
  return math.max(0, math.min(100, math.floor(v)))
end

-- Secondary line for a station row: whatever the API gave us, else the host.
local function specLine(st)
  local parts = {}
  if type(st.country) == "string" and st.country ~= "" then
    table.insert(parts, st.country)
  end
  if type(st.codec) == "string" and st.codec ~= "" then
    table.insert(parts, string.upper(st.codec))
  end
  local br = tonumber(st.bitrate)
  if br and br > 0 then
    table.insert(parts, tostring(math.floor(br)) .. " kbps")
  end
  if #parts == 0 then
    local host = string.match(st.url or "", "^%w+://([^/:]+)")
    if host then
      table.insert(parts, host)
    end
  end
  return table.concat(parts, " · ")
end

-- Decorative tuner bars: dance while playing, rest flat while stopped.
-- Driven by the panel's second ticks, so it costs nothing while closed.
local function eqValues()
  local bars = {}
  local t = os.time()
  local live = isPlaying()
  for i = 1, 28 do
    if live then
      local v = 0.3 + 0.28 * math.sin(t * 2.1 + i * 0.7) + 0.18 * math.sin(t * 3.7 + i * 1.9)
      bars[i] = math.max(0.08, math.min(1, v))
    else
      bars[i] = 0.07
    end
  end
  return bars
end

local function stationRow(st, key)
  local live = isPlaying() and stationId(st) == currentId()
  local fav = isFavorite(st)
  return ui.row({ key = key, gap = 10, align = "center" }, {
    ui.button({
      glyph = live and "player-stop-filled" or "player-play-filled",
      variant = live and "primary" or "ghost",
      controlSize = "sm",
      tooltip = live and noctalia.tr("panel.stop") or (noctalia.tr("panel.play") .. " " .. st.name),
      onClick = function()
        if live then
          sendCommand({ type = "stop" })
        else
          sendCommand({ type = "play", station = st })
        end
      end,
    }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({
        text = st.name,
        maxLines = 1,
        fontWeight = live and "semibold" or "normal",
        color = live and "primary" or "on_surface",
      }),
      ui.label({ text = specLine(st), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = fav and "star-filled" or "star",
      variant = "ghost",
      controlSize = "sm",
      tooltip = fav and noctalia.tr("panel.unfavorite") or noctalia.tr("panel.favorite"),
      onClick = function() sendCommand({ type = "favorite", station = st }) end,
    }),
  })
end

-- Preset tile for the folder view. No ui.grid exists, so tiles are laid out
-- as rows of two; the last odd tile gets a spacer so it keeps tile width
-- instead of stretching across the row.
local function presetTile(st, key)
  local live = isPlaying() and stationId(st) == currentId()
  local fav = isFavorite(st)
  return ui.column({
    key = key,
    flexGrow = 1,
    gap = 6,
    padding = 10,
    fill = live and "primary/0.18" or "surface_variant/0.45",
    radius = 0,
    onClick = function()
      if live then
        sendCommand({ type = "stop" })
      else
        sendCommand({ type = "play", station = st })
      end
    end,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({
        name = live and "player-stop-filled" or "player-play-filled",
        size = 14,
        color = live and "primary" or "on_surface_variant",
      }),
      ui.label({
        text = st.name,
        fontSize = 12,
        maxLines = 2,
        flexGrow = 1,
        fontWeight = live and "semibold" or "normal",
        color = live and "primary" or "on_surface",
      }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = specLine(st), fontSize = 10, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
      ui.button({
        glyph = fav and "star-filled" or "star",
        variant = "ghost",
        controlSize = "sm",
        tooltip = fav and noctalia.tr("panel.unfavorite") or noctalia.tr("panel.favorite"),
        onClick = function() sendCommand({ type = "favorite", station = st }) end,
      }),
    }),
  })
end

local function tileRows(list, prefix)
  local rows = {}
  local i = 1
  while i <= #list do
    local cells = { presetTile(list[i], prefix .. i) }
    if list[i + 1] then
      table.insert(cells, presetTile(list[i + 1], prefix .. (i + 1)))
    else
      table.insert(cells, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(rows, ui.row({ key = prefix .. "row-" .. i, gap = 8 }, cells))
    i = i + 2
  end
  return rows
end

function render()
  if not open then
    return
  end

  local live = isPlaying()
  local vol = currentVolume()
  local nowName = noctalia.state.get("stationName")
  if type(nowName) ~= "string" or nowName == "" then
    nowName = noctalia.tr("panel.idle")
  end

  local nowState
  if live then
    nowState = noctalia.tr("panel.on_air")
  elseif currentId() ~= "" then
    nowState = noctalia.tr("panel.stopped")
  else
    nowState = noctalia.tr("panel.pick_station")
  end

  local body = {
    -- Receiver face: tuner display + transport + volume.
    ui.column({ gap = 10, fill = "surface_variant/0.55", radius = 0, padding = 16 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = live and "radio" or "radio-off", size = 20, color = "primary" }),
        ui.column({ flexGrow = 1, gap = 1 }, {
          ui.label({ text = nowName, fontSize = 15, fontWeight = "bold", maxLines = 1 }),
          ui.label({
            text = nowState,
            fontSize = 11,
            fontWeight = "medium",
            color = live and "primary" or "on_surface_variant",
            maxLines = 1,
          }),
        }),
        ui.button({
          glyph = live and "player-stop-filled" or "player-play-filled",
          glyphSize = 22,
          variant = "primary",
          controlSize = "lg",
          tooltip = live and noctalia.tr("panel.stop") or noctalia.tr("panel.play"),
          onClick = "onTogglePlay",
        }),
      }),
      ui.graph({ values = eqValues(), color = "primary", fillOpacity = 0.35, height = 42 }),
      -- Slider is value-driven (unlike ui.input): pass the current volume on
      -- every render or it snaps back to a stale position. Commit on
      -- onDragEnd, not onChange -- a volume change restarts mpv, so reacting
      -- to every intermediate position would restart the stream repeatedly.
      ui.row({ gap = 10, align = "center" }, {
        ui.glyph({ name = "volume-2", size = 15, color = "on_surface_variant" }),
        ui.slider({
          min = 0,
          max = 100,
          step = 5,
          value = vol,
          flexGrow = 1,
          controlSize = "sm",
          -- ui.slider hands onChange's value back as a STRING on this
          -- Noctalia build (contra the runtime-api docs) -- tonumber() it
          -- before math.floor(). onDragEnd is worse: it fires with NO value
          -- argument at all (v is nil), so it cannot be trusted for the
          -- final number -- it only means "drag finished, commit what
          -- onChange last recorded". Fall back to pendingVolume, then to
          -- the last known-good volume (currentVolume() is never nil) --
          -- a click-to-jump with no preceding onChange would otherwise
          -- drop the commit silently, with no log line to catch it.
          onChange = function(v)
            local n = tonumber(v)
            if n then
              pendingVolume = math.floor(n)
              render()
            end
          end,
          onDragEnd = function(v)
            local n = tonumber(v) or pendingVolume or currentVolume()
            pendingVolume = nil
            sendCommand({ type = "volume", volume = math.floor(n) })
          end,
        }),
        ui.label({
          text = tostring(vol) .. "%",
          fontSize = 12,
          color = "on_surface_variant",
          width = 40,
          textAlign = "end",
        }),
      }),
    }),
    -- Dial: search. ui.input seeds its value ONCE, so no `value` prop here --
    -- re-rendering must never overwrite what the user is typing.
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "search",
        placeholder = noctalia.tr("panel.search_placeholder"),
        flexGrow = 1,
        submitOnEnter = true,
        onChange = "onSearchInput",
        onSubmit = "onSearchSubmit",
      }),
      ui.button({
        glyph = "search",
        variant = "secondary",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.search"),
        onClick = "onSearchClicked",
      }),
    }),
  }

  if view == "folder" then
    table.insert(body, ui.row({ gap = 8, align = "center" }, {
      ui.button({
        glyph = "arrow-left",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.back"),
        onClick = "onBack",
      }),
      ui.label({ text = noctalia.tr("panel.metal_folder"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant", flexGrow = 1 }),
    }))
    for _, row in ipairs(tileRows(listOf("presets"), "preset-")) do
      table.insert(body, row)
    end
  elseif view == "search" then
    local state = noctalia.state.get("searchState")
    local results = listOf("searchResults")
    table.insert(body, ui.row({ gap = 8, align = "center" }, {
      ui.button({
        glyph = "arrow-left",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.back"),
        onClick = "onBack",
      }),
      ui.label({ text = noctalia.tr("panel.results"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant", flexGrow = 1 }),
    }))
    if state == "loading" then
      table.insert(body, ui.label({ text = noctalia.tr("panel.tuning"), color = "on_surface_variant" }))
    elseif state == "error" then
      table.insert(body, ui.label({ text = noctalia.tr("panel.search_error"), color = "on_surface_variant" }))
    elseif state == "empty" or (#results == 0 and state == "done") then
      table.insert(body, ui.label({ text = noctalia.tr("panel.no_results"), color = "on_surface_variant" }))
    else
      for i, st in ipairs(results) do
        table.insert(body, stationRow(st, "res-" .. i))
      end
    end
  else
    -- home: the Metal folder card, then saved favorites.
    table.insert(body, ui.row({
      key = "folder-metal",
      gap = 10,
      align = "center",
      padding = 12,
      fill = "surface_variant/0.45",
      radius = 0,
      onClick = "onOpenFolder",
    }, {
      ui.glyph({ name = "folder", size = 18, color = "primary" }),
      ui.column({ flexGrow = 1, gap = 1 }, {
        ui.label({ text = noctalia.tr("panel.metal_folder"), fontWeight = "semibold", maxLines = 1 }),
        ui.label({
          text = tostring(#listOf("presets")) .. " " .. noctalia.tr("panel.stations_count"),
          fontSize = 11,
          color = "on_surface_variant",
          maxLines = 1,
        }),
      }),
      ui.glyph({ name = "chevron-right", size = 16, color = "on_surface_variant" }),
    }))

    local favs = listOf("favorites")
    table.insert(body, ui.label({
      text = noctalia.tr("panel.favorites"),
      fontSize = 11,
      fontWeight = "bold",
      color = "on_surface_variant",
    }))
    if #favs == 0 then
      table.insert(body, ui.label({ text = noctalia.tr("panel.no_favorites"), color = "on_surface_variant" }))
    else
      for i, st in ipairs(favs) do
        table.insert(body, stationRow(st, "fav-" .. i))
      end
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 14, padding = 16 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onClosePanel" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, body),
  }))
end

noctalia.state.watch("playing", function(_) render() end)
noctalia.state.watch("stationName", function(_) render() end)
noctalia.state.watch("volume", function(_) render() end)
noctalia.state.watch("favorites", function(_) render() end)
noctalia.state.watch("searchResults", function(_) render() end)
noctalia.state.watch("searchState", function(_) render() end)

function update()
  -- Second ticks drive the tuner animation while the panel is open.
  render()
end

function onOpen(_context)
  open = true
  view = "home"
  query = ""
  pendingVolume = nil
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  open = false
end

function onSearchInput(value)
  query = tostring(value or "")
end

function onSearchSubmit(value)
  query = noctalia.string.trim(tostring(value or query))
  if query == "" then
    view = "home"
  else
    view = "search"
    sendCommand({ type = "search", query = query })
  end
  render()
end

function onSearchClicked()
  onSearchSubmit(query)
end

function onOpenFolder()
  view = "folder"
  render()
end

function onBack()
  view = "home"
  render()
end

function onTogglePlay() sendCommand({ type = "toggle" }) end
function onClosePanel() panel.close() end
