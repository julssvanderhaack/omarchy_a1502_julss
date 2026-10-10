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


XDG_KINDS = {
    "DOWNLOAD": "downloads", "DOCUMENTS": "documents", "MUSIC": "music",
    "PICTURES": "pictures", "VIDEOS": "videos", "DESKTOP": "desktop",
    "TEMPLATES": "templates", "PUBLICSHARE": "public",
}

# Carpetas sin ruta XDG, reconocidas por su nombre (en minúsculas).
NAME_KINDS = {
    "dropbox": "dropbox",
    "nextcloud": "cloud", "onedrive": "cloud", "google drive": "cloud", "mega": "cloud", "drive": "cloud",
    "proyectos": "code", "projects": "code", "code": "code", "src": "code", "dev": "code", "git": "code", "repos": "code",
    "juegos": "games", "games": "games", "roms": "games",
    "libros": "books", "books": "books",
    "trabajo": "work", "work": "work",
    "descargas": "downloads", "downloads": "downloads",
    "documentos": "documents", "documents": "documents",
    "música": "music", "musica": "music", "music": "music",
    "imágenes": "pictures", "imagenes": "pictures", "pictures": "pictures", "fotos": "pictures", "photos": "pictures",
    "vídeos": "videos", "videos": "videos",
    "escritorio": "desktop", "desktop": "desktop",
    "plantillas": "templates", "templates": "templates",
    "público": "public", "publico": "public", "public": "public",
}


def xdg_dirs():
    """Ruta -> tipo, según xdg-user-dir (ignora las que apuntan a $HOME)."""
    home = os.path.realpath(os.path.expanduser("~"))
    found = {}
    for key, kind in XDG_KINDS.items():
        try:
            out = subprocess.run(["xdg-user-dir", key], capture_output=True, text=True, timeout=2).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            continue
        real = os.path.realpath(out) if out else ""
        if real and real != home:
            found[real] = kind
    return found


def folder_kind(path, xdg):
    real = os.path.realpath(path)
    if real in xdg:
        return xdg[real]
    return NAME_KINDS.get(os.path.basename(real.rstrip("/")).lower(), "folder")


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
                items.append({"label": label, "path": folder_path, "kind": folder_kind(folder_path, XDG)})
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


XDG = xdg_dirs()


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
