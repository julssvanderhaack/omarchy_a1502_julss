#!/bin/bash
# Ir a la app que mandó una notificación del panel: enfoca su ventana si ya
# está abierta, si no la lanza.
#   open-app.sh <app> <appIcon> <webHost> <execArgvJson>
# webHost = "web.whatsapp.com" etc. para notificaciones de web-apps de Chromium.
# execArgvJson = acción propia (omarchy-action); si viene, se ejecuta tal cual.

app="$1" app_icon="$2" host="$3" exec_json="$4"

if [[ -n $exec_json && $exec_json != "[]" ]]; then
  mapfile -t argv < <(jq -r '.[]' <<<"$exec_json" 2>/dev/null)
  ((${#argv[@]})) && exec setsid "${argv[@]}"
fi

clients=$(hyprctl clients -j)

focus() { # $1 = jq filter over a client, true if it matches
  local addr
  addr=$(jq -r "[.[] | select($1)][0].address // empty" <<<"$clients")
  [[ -n $addr ]] || return 1
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1 ||
    hyprctl dispatch focuswindow "address:$addr" >/dev/null
  exit 0
}

launch_desktop() {
  # Ids con espacios (juegos de Steam, etc.) no son ids válidos para uwsm.
  [[ $(basename "$1") == *" "* ]] && exec setsid gio launch "$1"
  exec setsid uwsm-app -- "$(basename "$1")"
}

app_dirs=("${XDG_DATA_HOME:-$HOME/.local/share}/applications")
IFS=: read -ra sys <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for d in "${sys[@]}"; do app_dirs+=("$d/applications"); done
desktops() { find "${app_dirs[@]}" -maxdepth 1 -name '*.desktop' 2>/dev/null; }

if [[ -n $host ]]; then
  # Web-app de Chromium: ventana propia con clase chrome-<host>__-<perfil>.
  focus "(.class | startswith(\"chrome-${host}__\")) or (.initialClass | startswith(\"chrome-${host}__\"))"
  file=$(desktops | xargs -r -d '\n' grep -l -- "^Exec=.*$host" 2>/dev/null | head -n1)
  [[ -n $file ]] && launch_desktop "$file"
  # Pestaña normal del navegador: ir al navegador, o abrir la web.
  b=$(tr '[:upper:]' '[:lower:]' <<<"$app")
  focus "(.class | ascii_downcase) == \"$b\""
  exec setsid xdg-open "https://$host/"
fi

lower=$(tr '[:upper:]' '[:lower:]' <<<"$app")
squashed=${lower// /}
first=${lower%% *}

# .desktop de la app: por nombre, por id, o por el icono si es un nombre.
file=""
icon_id=""
[[ -n $app_icon && $app_icon != /* && $app_icon != *://* ]] && icon_id="$app_icon"
while read -r f; do
  id=$(basename "$f" .desktop)
  name=$(grep -m1 '^Name=' "$f" | cut -d= -f2- | tr '[:upper:]' '[:lower:]')
  if [[ ${id,,} == "${icon_id,,}" && -n $icon_id ]] || [[ $name == "$lower" ]] || [[ ${id,,} == "$squashed" ]]; then
    file="$f"; break
  fi
  [[ -z $file && -n $first && ${#first} -ge 4 && ( $name == "$first" || ${id,,} == *".$first"* || ${id,,} == "$first"* ) ]] && cand="${cand:-$f}"
done < <(desktops)
file="${file:-$cand}"

classes=("$squashed" "$first")
if [[ -n $file ]]; then
  wm=$(grep -m1 '^StartupWMClass=' "$file" | cut -d= -f2-)
  classes+=("$(basename "$file" .desktop)" "$wm")
fi
[[ -n $icon_id ]] && classes+=("$icon_id")

filter=""
for c in "${classes[@]}"; do
  c=${c,,}
  [[ -z $c || ${#c} -lt 3 ]] && continue
  filter+="${filter:+ or }((.class | ascii_downcase) == \"$c\") or ((.initialClass | ascii_downcase) == \"$c\")"
done
[[ -n $filter ]] && focus "$filter"
# Parecido más laxo: la clase contiene el nombre (org.telegram.desktop ↔ telegram).
[[ ${#first} -ge 4 ]] && focus "(.class | ascii_downcase | contains(\"$first\"))"

[[ -n $file ]] && launch_desktop "$file"
exit 1
