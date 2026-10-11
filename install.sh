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

# Hook theme-set: recolorea GTK con la paleta del tema (bin/julss-gtk-theme-colors)
backup_and_copy "$REPO_DIR/omarchy/hooks/theme-set.d/julss-gtk-colors" "$CONFIG_DIR/omarchy/hooks/theme-set.d/julss-gtk-colors"

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
"$HOME/.local/bin/julss-gtk-theme-colors" 2>/dev/null || true

# Iconos Papirus-Dark con carpetas cian (el hook julss-icons lo mantiene al cambiar de tema)
backup_and_copy "$REPO_DIR/omarchy/hooks/theme-set.d/julss-icons" "$CONFIG_DIR/omarchy/hooks/theme-set.d/julss-icons"
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
