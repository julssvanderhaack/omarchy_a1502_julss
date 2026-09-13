-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.

-- See current bindings and descriptions:
--   omarchy menu keybindings --print

-- To disable every Omarchy default binding, set this in
-- ~/.config/hypr/hyprland.lua before require("default.hypr.omarchy"), then add
-- only the bindings you want below:
--   omarchy_default_bindings = false

-- To disable all preinstalled app/webapp bindings, set:
--   omarchy_preinstalled_bindings = false

-- Add a new binding.
-- o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh your-server")

-- Change an existing binding by unbinding it first, then binding the key again.
-- This example changes SUPER+SPACE from the launcher to the Omarchy root menu.
-- hl.unbind("SUPER + SPACE")
-- o.bind("SUPER + SPACE", "Omarchy menu", "omarchy-menu toggle root")

-- Disable a default binding without replacing it.
-- hl.unbind("SUPER + SHIFT + B")

-- Logitech MX Keys examples:
hl.unbind("SUPER + SHIFT + S")
o.bind("SUPER + SHIFT + S", "Captura de pantalla", "omarchy-capture-screenshot")
hl.unbind("SUPER + SHIFT + E")

o.bind("SUPER + SHIFT + E","Explorador de archivos","nautilus")
--o.bind("XF86LaunchA", "Vista de ventanas", "hyprctl dispatch overview:toggle")
o.bind("XF86LaunchA", "Portapapeles", "omarchy menu clipboard")
--o.bind("XF86LaunchB", "Nautilus", "omarchy menu toggle apps")
o.bind("XF86LaunchB","Nautilus", "nautilus")

hl.unbind("SUPER + SHIFT + M")
hl.unbind("SUPER + M")
hl.unbind("SUPER + B")
o.bind("SUPER + SHIFT + M", "Telegram", "Telegram")
o.bind("SUPER + + M", "Telegram", "Telegram")
o.bind("SUPER + B","Chromium Browser","chromium")
hl.unbind("SUPER + Z")
o.bind("SUPER + Z", "Spotify", "spotify")

--o.bind("SUPER + E","
-- o.bind("SUPER + SHIFT + S", nil, "omarchy-capture-screenshot")
-- o.bind("SUPER + B","chromium")
-- o.bind("SUPER + H", nil, "voxtype record toggle")
-- o.bind("SUPER + PERIOD", nil, "omarchy-shell shell toggle omarchy.emojis")

-- Alt+Tab switcher plugin (vbrosseau.alttab) — without this include the
-- plugin can't find its keybinding and shows a "No keybinding found" error.
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/vbrosseau.alttab/omarchy-plugin/alttab-bindings.lua")

