#!/bin/bash
# Unmounts every mounted partition under a block device and then powers it
# off (or ejects it, for optical media). Usage: eject.sh /dev/sdb
set -uo pipefail

parent="${1:-}"
if [[ -z "$parent" || ! -b "$parent" ]]; then
  echo "usage: eject.sh <block-device>" >&2
  exit 1
fi

status=0

while IFS= read -r line; do
  NAME=""
  MOUNTPOINT=""
  eval "$line"
  if [[ -n "$MOUNTPOINT" ]]; then
    udisksctl unmount -b "$NAME" || status=1
  fi
done < <(lsblk -p -P -o NAME,MOUNTPOINT "$parent" 2>/dev/null)

if ! udisksctl power-off -b "$parent" 2>/dev/null; then
  eject "$parent" 2>/dev/null || status=1
fi

exit "$status"
