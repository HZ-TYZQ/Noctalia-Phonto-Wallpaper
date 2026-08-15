--!nonstrict
-- Bar widget that opens the Phonto video wallpaper picker.

local glyph = noctalia.getConfig("glyph")

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("tyzq/phonto-wallpaper:picker")
end

render()
