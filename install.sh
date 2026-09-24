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

# own scripts (menu actions) into ~/.local/bin
for f in "$REPO_DIR"/bin/*; do
  backup_and_copy "$f" "$HOME/.local/bin/$(basename "$f")"
done

# own plugins
for p in "$REPO_DIR"/plugins/*/; do
  name=$(basename "$p")
  backup_and_copy "$p" "$CONFIG_DIR/omarchy/plugins/$name"
done

echo
echo "Hecho. Ahora ejecuta: omarchy restart shell && hyprctl reload"
echo "Revisa el README para reinstalar plugins/temas de terceros."
