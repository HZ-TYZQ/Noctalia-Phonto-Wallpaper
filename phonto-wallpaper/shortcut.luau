--!nonstrict
-- Control center tile that opens the Phonto video wallpaper picker.

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("movie")
end

render()

function onClick()
  noctalia.togglePanel("tyzq/phonto-wallpaper:picker")
end
