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
o.bind("SUPER + SHIFT + S", "Captura de area de pantalla", "omarchy-capture-screenshot")
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
o.bind("SUPER + M", "Telegram", "Telegram")
o.bind("SUPER + B","Chromium Browser","chromium")
hl.unbind("SUPER + Z")
o.bind("SUPER + Z", "Spotify", "spotify")
hl.unbind("SUPER + SHIFT + C")
-- Captura de toda la pantalla sin seleccionar área (guarda, copia al
-- portapapeles y avisa con opción de editar, como la tecla Imprimir).
o.bind("SUPER + SHIFT + C", "Captura de pantalla completa", "omarchy-capture-screenshot fullscreen")

--o.bind("SUPER + E","
-- o.bind("SUPER + SHIFT + S", nil, "omarchy-capture-screenshot")
-- o.bind("SUPER + B","chromium")
-- o.bind("SUPER + H", nil, "voxtype record toggle")
-- o.bind("SUPER + PERIOD", nil, "omarchy-shell shell toggle omarchy.emojis")

-- Alt+Tab switcher plugin (vbrosseau.alttab) — without this include the
-- plugin can't find its keybinding and shows a "No keybinding found" error.
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/vbrosseau.alttab/omarchy-plugin/alttab-bindings.lua")


-- Claude Code en una terminal (ruta absoluta: mise no está en el PATH de Hyprland)
o.bind("SUPER + A", "Claude", { tui = os.getenv("HOME") .. "/.local/share/mise/installs/claude/latest/claude" })

-- Menú de atajos en castellano (antes: omarchy-menu-keybindings, en inglés).
hl.unbind("SUPER + K")
o.bind("SUPER + K", "Keybindings", "julss-menu-keybindings")

-- Teclas de volumen rápidas (antes: omarchy-audio-output-volume, ~240 ms por
-- pulsación, el OSD iba a trompicones). julss-volume solo usa wpctl y el OSD lo
-- pinta julss.audio al ver el cambio en PipeWire.
hl.unbind("XF86AudioRaiseVolume")
hl.unbind("XF86AudioLowerVolume")
hl.unbind("ALT + XF86AudioRaiseVolume")
hl.unbind("ALT + XF86AudioLowerVolume")
hl.unbind("XF86AudioMute")
o.bind("XF86AudioRaiseVolume", "Subir volumen", "julss-volume raise", { locked = true, repeating = true })
o.bind("XF86AudioLowerVolume", "Bajar volumen", "julss-volume lower", { locked = true, repeating = true })
o.bind("ALT + XF86AudioRaiseVolume", "Subir volumen (fino)", "julss-volume +1", { locked = true, repeating = true })
o.bind("ALT + XF86AudioLowerVolume", "Bajar volumen (fino)", "julss-volume -1", { locked = true, repeating = true })
o.bind("XF86AudioMute", "Silenciar", "julss-volume mute-toggle", { locked = true })

-- Calculadora científica propia (julss-calc, ~/src/julss-calc) en lugar de omacalc.
-- Si ya está abierta, la enfoca en vez de abrir otra.
hl.unbind("SUPER + CTRL + Q")
hl.unbind("XF86Calculator")
o.bind("SUPER + CTRL + Q", "Calculator", "omarchy-launch-or-focus julss-calc")
o.bind("XF86Calculator", "Calculator", "omarchy-launch-or-focus julss-calc")
