-- Bar widget: shows the current station (or an idle glyph) and is the
-- quickest control surface -- left-click opens the panel, right-click
-- toggles playback without opening anything, scroll steps through stations.
--
-- Read-only view of the service's state; every gesture goes through the
-- command channel, never near the mpv process itself.

local PANEL_ID = "nyx/radio-player:player"

local function sendCommand(cmd)
  cmd.seq = noctalia.nowMs()
  noctalia.state.set("command", cmd)
end

local function render()
  local playing = noctalia.state.get("playing") == true
  barWidget.setGlyph(playing and "player-play" or "radio")
  local name = noctalia.state.get("stationName")
  barWidget.setText(playing and name or "")
  if playing and name then
    barWidget.setTooltip({
      { key = noctalia.tr("widget.now_playing"), value = name },
      { key = noctalia.tr("widget.volume"), value = tostring(noctalia.state.get("volume") or "") },
    })
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip"))
  end
end

render()
noctalia.state.watch("playing", function(_) render() end)
noctalia.state.watch("stationName", function(_) render() end)
noctalia.state.watch("volume", function(_) render() end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  sendCommand({ type = "toggle" })
end

-- Station stepping through favorites: a wheel flick emits several detents
-- that the user means as one move, so act only on startsGesture and let the
-- rest of the burst fall through. (Ramping a value would do the opposite.)
-- The service falls back to the metal presets while no favorite is saved,
-- so this is never a dead gesture on a fresh install.
function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture then
    return
  end
  sendCommand({ type = "step", delta = steps > 0 and 1 or -1 })
end
