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
