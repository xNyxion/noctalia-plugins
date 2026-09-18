-- Bar widget: shows current station (or idle glyph), left-click opens the player panel.

local PANEL_ID = "nyx/radio-player:player"

local function render()
  local playing = noctalia.state.get("playing") == true
  barWidget.setGlyph(playing and "player-play" or "radio")
  local name = noctalia.state.get("stationName")
  barWidget.setText(playing and name or "")
  barWidget.setTooltip(name or noctalia.tr("widget.tooltip"))
end

render()
noctalia.state.watch("playing", function(_) render() end)
noctalia.state.watch("stationName", function(_) render() end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
