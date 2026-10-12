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


# Iconos simbólicos por tipo, buscados en el tema de iconos GTK elegido
# (gsettings icon-theme, el que fija julss-appearance) siguiendo su Inherits,
# como hace GTK. Se prueban los nombres en orden.
ICON_NAMES = {
    "home": ["user-home-symbolic"],
    "downloads": ["folder-download-symbolic"],
    "documents": ["folder-documents-symbolic"],
    "music": ["folder-music-symbolic"],
    "pictures": ["folder-pictures-symbolic"],
    "videos": ["folder-videos-symbolic"],
    "desktop": ["user-desktop-symbolic"],
    "templates": ["folder-templates-symbolic"],
    "public": ["folder-publicshare-symbolic"],
    "dropbox": ["folder-dropbox-symbolic", "dropbox-symbolic"],
    "code": ["folder-code-symbolic", "applications-development-symbolic"],
    "cloud": ["folder-cloud-symbolic", "folder-remote-symbolic"],
    "games": ["folder-games-symbolic", "applications-games-symbolic"],
    "books": ["folder-books-symbolic", "accessories-dictionary-symbolic"],
    "work": ["folder-work-symbolic"],
    "folder": ["folder-symbolic"],
    "device": ["drive-removable-media-symbolic", "drive-harddisk-symbolic"],
    "optical": ["media-optical-symbolic", "drive-optical-symbolic"],
}
ICON_BASES = [os.path.expanduser("~/.local/share/icons"), os.path.expanduser("~/.icons"), "/usr/share/icons"]
ICON_SIZE = 16


def theme_dir(name):
    for base in ICON_BASES:
        d = os.path.join(base, name)
        if os.path.isfile(os.path.join(d, "index.theme")):
            return d
    return None


def parse_index(path):
    """Devuelve (Inherits, [(subdir, size, scalable)])."""
    sections, cur = {}, None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                cur = sections.setdefault(line[1:-1], {})
            elif cur is not None and "=" in line:
                k, v = line.split("=", 1)
                cur[k.strip()] = v.strip()
    main = sections.get("Icon Theme", {})
    inherits = [x for x in main.get("Inherits", "").split(",") if x]
    dirs = []
    for d in (main.get("Directories", "") + "," + main.get("ScaledDirectories", "")).split(","):
        if d and d in sections:
            sec = sections[d]
            try:
                size = int(sec.get("Size", "0"))
            except ValueError:
                size = 0
            dirs.append((d, size, sec.get("Type", "") == "Scalable"))
    return inherits, dirs


def theme_chain():
    try:
        name = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"],
                              capture_output=True, text=True, timeout=2).stdout.strip().strip("'")
    except (OSError, subprocess.TimeoutExpired):
        name = ""
    chain, queue = [], [name or "hicolor"]
    while queue:
        t = queue.pop(0)
        if t in [c[0] for c in chain]:
            continue
        d = theme_dir(t)
        if not d:
            continue
        inherits, dirs = parse_index(os.path.join(d, "index.theme"))
        # Mejor primero el tamaño más cercano a 16 (los Scalable cuentan como exactos).
        dirs.sort(key=lambda x: (0 if x[2] else abs(x[1] - ICON_SIZE), "@" in x[0]))
        chain.append((t, d, dirs))
        queue += inherits
    if "hicolor" not in [c[0] for c in chain] and theme_dir("hicolor"):
        d = theme_dir("hicolor")
        chain.append(("hicolor", d, parse_index(os.path.join(d, "index.theme"))[1]))
    return chain


def lookup_icon(chain, names):
    # Primero el tema más cercano (el elegido antes que los heredados), y
    # dentro de cada tema los nombres en orden.
    for _, d, dirs in chain:
        for name in names:
            for sub, _, _ in dirs:
                for ext in (".svg", ".png"):
                    f = os.path.join(d, sub, name + ext)
                    if os.path.isfile(f):
                        return f
    return ""


def resolve_icons():
    chain = theme_chain()
    out = {}
    for kind, names in ICON_NAMES.items():
        path = lookup_icon(chain, names)
        if path:
            out[kind] = path
    return {"theme": chain[0][0] if chain else "", "paths": out}


XDG = xdg_dirs()


def main():
    home = os.path.expanduser("~")
    result = {
        "home": {"label": "Inicio", "path": home},
        "bookmarks": read_bookmarks(),
        "media": collect_media(),
        "icons": resolve_icons(),
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
