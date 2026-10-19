#!/usr/bin/env python3
"""Ayudante de julss.flatpak: lee el estado de Flatpak y lo devuelve en JSON.

  flatpak.py installed            apps instaladas (+ resumen de runtimes)
  flatpak.py updates              actualizaciones pendientes
  flatpak.py search TEXTO         buscar en los remotos (Flathub)
  flatpak.py details ID INST      info, permisos y datos de una app
  flatpak.py inspect FICHERO      qué hay dentro de un .flatpak/.flatpakref/.flatpakrepo
  flatpak.py run -- CMD...        ejecuta CMD y emite su salida línea a línea
                                  (separa también los \\r de las barras de progreso)
"""

import configparser
import gzip
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

HOME = os.path.expanduser("~")
INSTALL_DIRS = {
    "system": "/var/lib/flatpak",
    "user": os.path.join(HOME, ".local/share/flatpak"),
}
CACHE = os.path.join(HOME, ".cache/julss-flatpak")
ARCH = os.uname().machine
C_ENV = dict(os.environ, LC_ALL="C", LANG="C")


def flatpak(*args, check=False):
    try:
        out = subprocess.run(["flatpak", *args], capture_output=True, text=True, env=C_ENV, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if check and out.returncode != 0:
        return None
    return out.stdout


def rows(text):
    return [line.split("\t") for line in (text or "").splitlines() if line.strip()]


def parse_size(text):
    """'54.9 MB' (flatpak usa unidades de 1000) -> bytes."""
    m = re.match(r"\s*([\d.,]+)\s*([kKMGT]?)B?", text or "")
    if not m:
        return 0
    num = float(m.group(1).replace(",", ""))
    mult = {"": 1, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}[m.group(2)]
    return int(num * mult)


def icon_for(app_id, installation=None, remote=None):
    sizes = ["128x128", "256x256", "scalable", "512x512", "64x64", "96x96", "48x48"]
    dirs = [INSTALL_DIRS[installation]] if installation in INSTALL_DIRS else list(INSTALL_DIRS.values())
    for base in dirs:
        for size in sizes:
            for ext in ("png", "svg"):
                path = os.path.join(base, "exports/share/icons/hicolor", size, "apps", app_id + "." + ext)
                if os.path.exists(path):
                    return path
    for base in dirs:
        remotes = [remote] if remote else _listdir(os.path.join(base, "appstream"))
        for r in remotes:
            for size in ("128x128", "64x64"):
                path = os.path.join(base, "appstream", r, ARCH, "active/icons", size, app_id + ".png")
                if os.path.exists(path):
                    return path
    return ""


def _listdir(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def dir_size(path):
    total = 0
    seen = set()
    for root, dirs, files in os.walk(path):
        for name in files:
            try:
                st = os.lstat(os.path.join(root, name))
            except OSError:
                continue
            if (st.st_dev, st.st_ino) in seen:
                continue
            seen.add((st.st_dev, st.st_ino))
            total += st.st_blocks * 512
    return total


# ---------- Instaladas ----------
def installed():
    cols = "application,name,version,branch,origin,installation,size,description,ref"
    apps = []
    for r in rows(flatpak("list", "--app", "--columns=" + cols)):
        r += [""] * (9 - len(r))
        app_id, name, version, branch, origin, inst, size, desc, ref = r[:9]
        apps.append({
            "id": app_id, "name": name or app_id, "version": version, "branch": branch,
            "origin": origin, "installation": inst, "size": parse_size(size),
            "summary": desc, "ref": ref, "icon": icon_for(app_id, inst),
        })
    apps.sort(key=lambda a: a["name"].lower())
    runtimes = rows(flatpak("list", "--runtime", "--columns=application,size"))
    return {
        "apps": apps,
        "runtimeCount": len(runtimes),
        "runtimeSize": sum(parse_size(r[1]) for r in runtimes if len(r) > 1),
    }


# ---------- Actualizaciones ----------
def updates():
    out = []
    names = {a["id"] + "/" + a["installation"]: a for a in installed()["apps"]}
    for inst in ("system", "user"):
        text = flatpak("remote-ls", "--" + inst, "--updates", "--columns=application,version,branch,origin,ref,download-size")
        for r in rows(text):
            r += [""] * (6 - len(r))
            app_id, version, branch, origin, ref, dl = r[:6]
            app = names.get(app_id + "/" + inst)
            out.append({
                "id": app_id, "name": app["name"] if app else app_id,
                "version": version, "oldVersion": app["version"] if app else "",
                "branch": branch, "origin": origin, "ref": ref, "installation": inst,
                "download": parse_size(dl), "runtime": ref.startswith("runtime/"),
                "icon": app["icon"] if app else icon_for(app_id, inst),
            })
    out.sort(key=lambda u: (u["runtime"], u["name"].lower()))
    return {"updates": out}


# ---------- Buscar ----------
def search(query):
    have = {}
    for a in installed()["apps"]:
        have[a["id"]] = a
    results = []
    text = flatpak("search", "--columns=application,name,version,branch,remotes,description", query)
    for r in rows(text):
        if r[0] == "No matches found":
            break
        r += [""] * (6 - len(r))
        app_id, name, version, branch, remotes, desc = r[:6]
        if app_id.endswith((".Locale", ".Debug", ".Sources")):
            continue
        remote = remotes.split(",")[0]
        results.append({
            "id": app_id, "name": name or app_id, "version": version, "branch": branch,
            "remote": remote, "summary": desc,
            "icon": icon_for(app_id, None, remote) or icon_for(app_id),
            "installed": app_id in have,
            "installation": have[app_id]["installation"] if app_id in have else "",
        })
    q = query.lower().strip()

    def rank(r):
        name, last = r["name"].lower(), r["id"].lower().rsplit(".", 1)[-1]
        addon = ".plugin." in r["id"].lower() or ".addon" in r["id"].lower() or "extension" in r["id"].lower()
        return (0 if q in (name, last) else 1 if name.startswith(q) or last.startswith(q) else 2, addon)

    results.sort(key=rank)
    return {"query": query, "results": results[:80]}


# ---------- Detalles ----------
def parse_context(metadata):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    try:
        cp.read_string(metadata or "")
    except configparser.Error:
        return {}
    ctx = {}
    if cp.has_section("Context"):
        for key, value in cp.items("Context"):
            ctx[key] = [v for v in value.split(";") if v]
    runtime = ""
    for section in ("Application", "Runtime"):
        if cp.has_section(section):
            runtime = cp.get(section, "runtime", fallback="")
            break
    return {"context": ctx, "runtime": runtime}


def details(app_id, inst):
    flag = "--" + (inst if inst in ("system", "user") else "system")
    info = {}
    for line in (flatpak("info", flag, app_id) or "").splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            info[k.strip()] = v.strip()
    meta = parse_context(flatpak("info", flag, "--show-metadata", app_id))
    data_dir = os.path.join(HOME, ".var/app", app_id)
    appdata = _appdata_xml(os.path.join(INSTALL_DIRS.get(inst, "/var/lib/flatpak"),
                                        "app", app_id, "current/active/export/share/metainfo"), app_id)
    if not appdata:
        appdata = _appdata_xml(os.path.join(INSTALL_DIRS.get(inst, "/var/lib/flatpak"),
                                            "app", app_id, "current/active/files/share/metainfo"), app_id)
    return {
        "id": app_id, "installation": inst,
        "license": info.get("License", ""), "origin": info.get("Origin", ""),
        "date": info.get("Date", ""), "runtime": info.get("Runtime", meta.get("runtime", "")),
        "installedSize": parse_size(info.get("Installed Size", "")), "commit": info.get("Commit", "")[:12],
        "permissions": meta.get("context", {}),
        "dataDir": data_dir if os.path.isdir(data_dir) else "",
        "dataSize": dir_size(data_dir) if os.path.isdir(data_dir) else 0,
        **appdata,
    }


def _appdata_xml(directory, app_id):
    for name in _listdir(directory):
        if name.endswith((".xml", ".xml.gz")):
            try:
                raw = open(os.path.join(directory, name), "rb").read()
                if name.endswith(".gz"):
                    raw = gzip.decompress(raw)
                return parse_appdata(raw, app_id)
            except (OSError, ValueError, ET.ParseError):
                pass
    return {}


def _localized(parent, tag):
    """Texto en español si lo hay; si no, el que no lleva xml:lang."""
    best = None
    for el in parent.findall(tag):
        lang = el.get("{http://www.w3.org/XML/1998/namespace}lang")
        if lang in ("es", "es_ES"):
            return el
        if lang is None and best is None:
            best = el
    return best


def _description_text(el):
    if el is None:
        return ""
    parts = []
    for child in el:
        if child.get("{http://www.w3.org/XML/1998/namespace}lang"):
            continue
        if child.tag == "p":
            parts.append(" ".join("".join(child.itertext()).split()))
        elif child.tag in ("ul", "ol"):
            for li in child:
                if li.get("{http://www.w3.org/XML/1998/namespace}lang"):
                    continue
                parts.append("• " + " ".join("".join(li.itertext()).split()))
    return "\n".join(p for p in parts if p)


def parse_appdata(raw, app_id=""):
    root = ET.fromstring(raw)
    comp = root if root.tag == "component" else None
    if comp is None:
        for c in root.iter("component"):
            cid = c.findtext("id") or ""
            if not app_id or cid.removesuffix(".desktop") == app_id:
                comp = c
                break
    if comp is None:
        return {}
    name = _localized(comp, "name")
    summary = _localized(comp, "summary")
    out = {
        "name": (name.text or "").strip() if name is not None else "",
        "summary": (summary.text or "").strip() if summary is not None else "",
        "description": _description_text(_localized(comp, "description")),
        "developer": (comp.findtext("developer/name") or comp.findtext("developer_name") or "").strip(),
    }
    for url in comp.findall("url"):
        if url.get("type") == "homepage":
            out["homepage"] = (url.text or "").strip()
    rel = comp.find("releases/release")
    if rel is not None and rel.get("version"):
        out["version"] = rel.get("version")
    return {k: v for k, v in out.items() if v}


# ---------- Ficheros .flatpak / .flatpakref / .flatpakrepo ----------
def installed_versions(app_id):
    found = []
    for a in installed()["apps"]:
        if a["id"] == app_id:
            found.append({"installation": a["installation"], "version": a["version"], "branch": a["branch"], "origin": a["origin"]})
    return found


def runtime_installed(runtime):
    """runtime = 'org.freedesktop.Platform/x86_64/24.08'."""
    if not runtime:
        return True
    parts = runtime.split("/")
    for r in rows(flatpak("list", "--runtime", "--columns=application,arch,branch")):
        if len(r) >= 3 and r[0] == parts[0] and (len(parts) < 3 or r[2] == parts[2]):
            return True
    return False


def inspect(path):
    path = os.path.abspath(path)
    base = {"file": path, "fileName": os.path.basename(path)}
    try:
        base["fileSize"] = os.path.getsize(path)
    except OSError:
        return {**base, "error": "No se puede leer el fichero"}
    low = path.lower()
    try:
        if low.endswith(".flatpakref"):
            return {**base, **inspect_ref(path)}
        if low.endswith(".flatpakrepo"):
            return {**base, **inspect_repo(path)}
        return {**base, **inspect_bundle(path)}
    except Exception as exc:  # noqa: BLE001 — se enseña en el panel
        return {**base, "error": "No se ha podido leer: " + str(exc)}


def inspect_bundle(path):
    from gi.repository import GLib

    raw = GLib.MappedFile.new(path, False).get_bytes()
    variant = GLib.Variant.new_from_bytes(GLib.VariantType.new("(a{sv}tayay(a(uayttay)a(yaytt)))"), raw, False)
    md = variant.get_child_value(0)

    def get(key, kind="s"):
        v = md.lookup_value(key, GLib.VariantType.new(kind))
        if v is None:
            return None
        return v.get_string() if kind == "s" else bytes(v.get_data_as_bytes().get_data())

    ref = get("ref") or ""
    kind, app_id, arch, branch = (ref.split("/") + ["", "", "", ""])[:4]
    meta = parse_context(get("metadata") or "")
    out = {
        "kind": "bundle", "ref": ref, "isRuntime": kind == "runtime", "id": app_id,
        "arch": arch, "branch": branch, "name": app_id, "runtimeRepo": get("runtime-repo") or "",
        "runtime": meta.get("runtime", ""), "permissions": meta.get("context", {}),
    }
    appdata = get("appdata", "ay")
    if appdata:
        try:
            out.update(parse_appdata(gzip.decompress(appdata), app_id))
        except (OSError, ValueError, ET.ParseError):
            pass
    icon = get("icon-128", "ay") or get("icon-64", "ay")
    if icon:
        os.makedirs(os.path.join(CACHE, "icons"), exist_ok=True)
        icon_path = os.path.join(CACHE, "icons", app_id + ".png")
        with open(icon_path, "wb") as fh:
            fh.write(icon)
        out["icon"] = icon_path
    else:
        out["icon"] = icon_for(app_id)
    out["runtimeInstalled"] = runtime_installed(out["runtime"])
    out["installed"] = installed_versions(app_id)
    if arch and arch != ARCH:
        out["warning"] = "Este paquete es para " + arch + " y este equipo es " + ARCH
    return out


def read_keyfile(path, section):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    with open(path, encoding="utf-8", errors="replace") as fh:
        cp.read_string(fh.read())
    if not cp.has_section(section):
        raise ValueError("falta la sección [" + section + "]")
    return dict(cp.items(section))


def inspect_ref(path):
    ref = read_keyfile(path, "Flatpak Ref")
    app_id = ref.get("Name", "")
    out = {
        "kind": "ref", "id": app_id, "branch": ref.get("Branch", "stable"),
        "isRuntime": ref.get("IsRuntime", "false").lower() == "true",
        "name": ref.get("Title", app_id), "summary": ref.get("Comment", ""),
        "description": ref.get("Description", ""), "homepage": ref.get("Homepage", ""),
        "url": ref.get("Url", ""), "runtimeRepo": ref.get("RuntimeRepo", ""),
        "suggestedRemote": ref.get("SuggestRemoteName", ""),
    }
    # Si la app está en un remoto que ya tenemos (lo normal: Flathub), sacamos
    # versión, tamaño e icono de ahí.
    remote = remote_for_url(out["url"])
    if remote:
        out["remote"] = remote
        info = {}
        for line in (flatpak("remote-info", "--system", remote, app_id + "//" + out["branch"]) or "").splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                info[k.strip()] = v.strip()
        out["version"] = info.get("Version", "")
        out["download"] = parse_size(info.get("Download Size", ""))
        out["installedSizeEstimate"] = parse_size(info.get("Installed Size", ""))
        out["license"] = info.get("License", "")
        out["runtime"] = info.get("Runtime", "")
        out["runtimeInstalled"] = runtime_installed(out["runtime"])
        out["icon"] = icon_for(app_id, "system", remote)
        appstream = search_appstream(remote, app_id)
        # El Title de los .flatpakref de Flathub es "org.x.App from flathub":
        # el nombre bueno es el del appstream.
        if appstream.get("name") and (out["name"] == app_id or " from " in out["name"]):
            out["name"] = appstream["name"]
        for key, value in appstream.items():
            if not out.get(key):
                out[key] = value
        meta = parse_context(flatpak("remote-info", "--system", "--show-metadata", remote, app_id + "//" + out["branch"]))
        out["permissions"] = meta.get("context", {})
    else:
        out["icon"] = icon_for(app_id)
    out["installed"] = installed_versions(app_id)
    return out


def remote_for_url(url):
    url = (url or "").rstrip("/")
    for r in rows(flatpak("remotes", "--system", "--columns=name,url")):
        if len(r) >= 2 and r[1].rstrip("/") == url:
            return r[0]
    return ""


def search_appstream(remote, app_id):
    path = os.path.join(INSTALL_DIRS["system"], "appstream", remote, ARCH, "active/appstream.xml.gz")
    try:
        raw = gzip.decompress(open(path, "rb").read())
    except OSError:
        return {}
    # El fichero entero son decenas de MB: buscamos solo el trozo de la app.
    key = ("<id>" + app_id + "</id>").encode()
    pos = raw.find(key)
    if pos < 0:
        return {}
    start = raw.rfind(b"<component", 0, pos)
    end = raw.find(b"</component>", pos)
    if start < 0 or end < 0:
        return {}
    try:
        return parse_appdata(raw[start:end + len("</component>")], app_id)
    except ET.ParseError:
        return {}


def inspect_repo(path):
    repo = read_keyfile(path, "Flatpak Repo")
    url = repo.get("Url", "")
    name = os.path.splitext(os.path.basename(path))[0]
    existing = remote_for_url(url)
    return {
        "kind": "repo", "id": name, "name": repo.get("Title", name),
        "summary": repo.get("Comment", ""), "description": repo.get("Description", ""),
        "homepage": repo.get("Homepage", ""), "url": url,
        "existingRemote": existing, "installed": [], "icon": "",
    }


# ---------- Ejecutar con salida en vivo ----------
def run(cmd):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    buf = b""
    while True:
        chunk = proc.stdout.read1(4096) if hasattr(proc.stdout, "read1") else proc.stdout.read(1)
        if not chunk:
            break
        buf += chunk
        parts = re.split(rb"[\r\n]", buf)
        buf = parts.pop()
        for part in parts:
            line = part.decode("utf-8", "replace").strip()
            if line:
                print(line, flush=True)
    if buf.strip():
        print(buf.decode("utf-8", "replace").strip(), flush=True)
    return proc.wait()


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "run":
        if args and args[0] == "--":
            args = args[1:]
        return run(args)
    if cmd == "installed":
        result = installed()
    elif cmd == "updates":
        result = updates()
    elif cmd == "search":
        result = search(" ".join(args))
    elif cmd == "details":
        result = details(args[0], args[1] if len(args) > 1 else "system")
    elif cmd == "inspect":
        result = inspect(args[0])
    else:
        print(__doc__)
        return 2
    json.dump(result, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
