#!/usr/bin/env python3
"""Emits JSON describing Nautilus bookmarks and mounted removable media.

Output shape:
{
  "home": {"label": "...", "path": "..."},
  "bookmarks": [{"label": "...", "path": "..."}, ...],
  "media": [
    {"label": "...", "mountpoint": "...", "device": "/dev/sdb1",
     "parent": "/dev/sdb", "size": "...", "fstype": "..."},
    ...
  ]
}
"""
import json
import os
import subprocess
from urllib.parse import unquote, urlparse


def read_bookmarks():
    path = os.path.expanduser("~/.config/gtk-3.0/bookmarks")
    items = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                parts = line.split(" ", 1)
                uri = parts[0]
                if not uri.startswith("file://"):
                    continue
                folder_path = unquote(urlparse(uri).path)
                label = parts[1].strip() if len(parts) > 1 and parts[1].strip() else (
                    os.path.basename(folder_path.rstrip("/")) or folder_path
                )
                items.append({"label": label, "path": folder_path})
    except OSError:
        pass
    return items


def collect_media():
    try:
        raw = subprocess.run(
            ["lsblk", "-J", "-p", "-o",
             "NAME,PKNAME,LABEL,MOUNTPOINT,RM,HOTPLUG,TRAN,SIZE,FSTYPE,TYPE"],
            capture_output=True, text=True, check=True, timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    try:
        tree = json.loads(raw)
    except json.JSONDecodeError:
        return []

    media = []

    def walk(node, ancestor_removable, top_device):
        is_removable = bool(node.get("rm")) or bool(node.get("hotplug")) \
            or node.get("tran") == "usb" or node.get("type") == "rom"
        removable = ancestor_removable or is_removable
        top = top_device or node.get("name")
        mountpoint = node.get("mountpoint")
        if mountpoint and mountpoint != "[SWAP]" and removable:
            label = node.get("label") or os.path.basename(mountpoint.rstrip("/")) or mountpoint
            media.append({
                "label": label,
                "mountpoint": mountpoint,
                "device": node.get("name"),
                "parent": top,
                "size": node.get("size") or "",
                "fstype": node.get("fstype") or "",
            })
        for child in node.get("children") or []:
            walk(child, removable, top)

    for device in tree.get("blockdevices") or []:
        walk(device, False, None)

    return media


def main():
    home = os.path.expanduser("~")
    result = {
        "home": {"label": "Inicio", "path": home},
        "bookmarks": read_bookmarks(),
        "media": collect_media(),
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
