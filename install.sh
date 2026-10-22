#!/bin/bash
# Copies this repo's own Omarchy config and plugins into place under ~/.config,
# backing up anything that already exists.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config"
STAMP=$(date +%s)

backup_and_copy() {
  local src=$1 dest=$2
  if [[ -e $dest ]]; then
    mv "$dest" "$dest.bak.$STAMP"
    echo "Backup: $dest -> $dest.bak.$STAMP"
  fi
  mkdir -p "$(dirname "$dest")"
  cp -r "$src" "$dest"
  echo "Instalado: $dest"
}

# hypr/*.lua and *.conf
for f in "$REPO_DIR"/hypr/*; do
  backup_and_copy "$f" "$CONFIG_DIR/hypr/$(basename "$f")"
done

# omarchy/shell.json and extensions
backup_and_copy "$REPO_DIR/omarchy/shell.json" "$CONFIG_DIR/omarchy/shell.json"
backup_and_copy "$REPO_DIR/omarchy/extensions/omarchy-menu.jsonc" "$CONFIG_DIR/omarchy/extensions/omarchy-menu.jsonc"
backup_and_copy "$REPO_DIR/omarchy/extensions/keybindings-es.tsv" "$CONFIG_DIR/omarchy/extensions/keybindings-es.tsv"

# own scripts (menu actions) into ~/.local/bin
for f in "$REPO_DIR"/bin/*; do
  backup_and_copy "$f" "$HOME/.local/bin/$(basename "$f")"
done


# Cursor Bibata Modern Ice en ~/.local/share/icons (hypr/hyprland.lua lo usa)
if [[ ! -d $HOME/.local/share/icons/Bibata-Modern-Ice ]]; then
  tmp=$(mktemp -d)
  if curl -fsSL -o "$tmp/c.tar.xz" https://github.com/ful1e5/Bibata_Cursor/releases/download/v2.0.7/Bibata-Modern-Ice.tar.xz &&
    tar xJf "$tmp/c.tar.xz" -C "$tmp"; then
    mkdir -p "$HOME/.local/share/icons"
    cp -r "$tmp/Bibata-Modern-Ice" "$HOME/.local/share/icons/"
  fi
  rm -rf "$tmp"
fi
gsettings set org.gnome.desktop.interface cursor-theme Bibata-Modern-Ice 2>/dev/null || true
"$HOME/.local/bin/julss-appearance" apply 2>/dev/null || true

# Iconos Papirus-Dark con carpetas cian (al cambiar de tema el hook julss-icons pone los del tema)
backup_and_copy "$REPO_DIR/omarchy/hooks/theme-set.d/julss-icons" "$CONFIG_DIR/omarchy/hooks/theme-set.d/julss-icons"
# Logo de la barra con los colores del logo de arranque del tema
backup_and_copy "$REPO_DIR/omarchy/hooks/theme-set.d/julss-bar-logo" "$CONFIG_DIR/omarchy/hooks/theme-set.d/julss-bar-logo"
"$HOME/.local/bin/julss-bar-logo" 2>/dev/null || true
if omarchy pkg add papirus-icon-theme; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/papirus-folders" https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/v1.14.0/papirus-folders &&
    bash "$tmp/papirus-folders" -C cyan --theme Papirus-Dark
  rm -rf "$tmp"
  gsettings set org.gnome.desktop.interface icon-theme Papirus-Dark 2>/dev/null || true
fi

# Iconos propios para Dropbox y Proyectos en Nautilus (vista de archivos)
[[ -d $HOME/Dropbox ]] && gio set "$HOME/Dropbox" metadata::custom-icon-name folder-dropbox 2>/dev/null
[[ -d $HOME/Projects ]] && gio set "$HOME/Projects" metadata::custom-icon-name folder-code 2>/dev/null

# julss-agent-crash: diagnosticar procesos caídos con un agente con tokens
backup_and_copy "$REPO_DIR/share/agent-shim/omarchy-default-agent" "$HOME/.local/share/julss/agent-shim/omarchy-default-agent"

# Gestor de Flatpak (julss.flatpak): abrir .flatpak/.flatpakref/.flatpakrepo desde Archivos
backup_and_copy "$REPO_DIR/share/applications/julss-flatpak.desktop" "$HOME/.local/share/applications/julss-flatpak.desktop"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
for m in application/vnd.flatpak application/vnd.flatpak.ref application/vnd.flatpak.repo; do
  xdg-mime default julss-flatpak.desktop "$m" 2>/dev/null || true
done

# Calculadora científica julss-calc (C++/Qt6 + Giac): compila e instala en ~/.local,
# la enlaza a Super+Ctrl+Q / tecla Calculadora (hypr/bindings.lua) y oculta omacalc
if omarchy pkg add giac cmake; then
  cmake -S "$REPO_DIR/apps/julss-calc" -B "$REPO_DIR/apps/julss-calc/build" -DCMAKE_BUILD_TYPE=Release &&
    cmake --build "$REPO_DIR/apps/julss-calc/build" -j"$(nproc)" &&
    cmake --install "$REPO_DIR/apps/julss-calc/build" --prefix "$HOME/.local"
fi
backup_and_copy "$REPO_DIR/share/applications/julss-calc.desktop" "$HOME/.local/share/applications/julss-calc.desktop"
backup_and_copy "$REPO_DIR/share/applications/omacalc.desktop" "$HOME/.local/share/applications/omacalc.desktop"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# Reproductor de música Sonata (C++/Qt6 + FFmpeg + PipeWire), en su propio repo
# (github.com/julssvanderhaack/sonata): lo clona o actualiza en ~/src/sonata,
# compila para esta CPU, instala en ~/.local y lo deja como aplicación por
# defecto para los archivos de audio
SONATA_DIR="$HOME/src/sonata"
if omarchy pkg add cmake ffmpeg; then
  if [ -d "$SONATA_DIR/.git" ]; then
    git -C "$SONATA_DIR" pull --ff-only || true
  else
    git clone https://github.com/julssvanderhaack/sonata.git "$SONATA_DIR"
  fi &&
    cmake -S "$SONATA_DIR" -B "$SONATA_DIR/build" -DCMAKE_BUILD_TYPE=Release &&
    cmake --build "$SONATA_DIR/build" -j"$(nproc)" &&
    cmake --install "$SONATA_DIR/build" --prefix "$HOME/.local" &&
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  [ -f "$SONATA_DIR/data/sonata.desktop" ] &&
    xdg-mime default sonata.desktop $(grep '^MimeType=' "$SONATA_DIR/data/sonata.desktop" | cut -d= -f2 | tr ';' ' ') 2>/dev/null || true
fi
# Luna, explorador de archivos propio (C++/Qt6): compila e instala en ~/.local.
# No se pone como explorador predeterminado (Nautilus sigue siéndolo).
if omarchy pkg add cmake qt6-svg libmediainfo exiv2 poppler-qt6 ffmpegthumbnailer gvfs gvfs-smb libarchive; then
  cmake -S "$REPO_DIR/apps/luna" -B "$REPO_DIR/apps/luna/build" -DCMAKE_BUILD_TYPE=Release &&
    cmake --build "$REPO_DIR/apps/luna/build" -j"$(nproc)" &&
    cmake --install "$REPO_DIR/apps/luna/build" --prefix "$HOME/.local" &&
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
fi
# PipeWire a la frecuencia nativa de cada canción (sin remuestrear 44,1 kHz)
backup_and_copy "$REPO_DIR/pipewire/10-julss-native-rates.conf" "$CONFIG_DIR/pipewire/pipewire.conf.d/10-julss-native-rates.conf"

# Chromium flags (VA-API video decode)
backup_and_copy "$REPO_DIR/chromium/chromium-flags.conf" "$CONFIG_DIR/chromium-flags.conf"

# ~/.bashrc (carga ble.sh para autosugerencias si está instalado)
backup_and_copy "$REPO_DIR/bash/bashrc" "$HOME/.bashrc"

# own plugins
for p in "$REPO_DIR"/plugins/*/; do
  name=$(basename "$p")
  backup_and_copy "$p" "$CONFIG_DIR/omarchy/plugins/$name"
done

# system files (MacBookPro12,1): need sudo, so ask first
echo
read -rp "¿Instalar también los ficheros de sistema de system/ (necesita sudo)? [s/N] " answer
if [[ $answer == [sS] ]]; then
  while IFS= read -r -d '' f; do
    dest="/${f#"$REPO_DIR"/system/}"
    sudo install -Dm"$(stat -c %a "$f")" "$f" "$dest"
    echo "Instalado: $dest"
  done < <(find "$REPO_DIR/system" -type f -print0)

  # ASPM L1 on the Thunderbolt 2 link, at boot and after resume
  sudo systemctl daemon-reload
  sudo systemctl enable --now thunderbolt-aspm.service
  echo "Los woofers (patch HDA) se activan tras reiniciar."
fi

echo
echo "Hecho. Ahora ejecuta: omarchy restart shell && hyprctl reload"
echo "Revisa el README para reinstalar plugins/temas de terceros."
