#!/usr/bin/env python3
"""Reparto del espacio en disco para el panel julss.disk.

Recorre un directorio (por defecto /) sumando el espacio real ocupado
(st_blocks), sin salir del sistema de ficheros: entra en los subvolúmenes
btrfs del mismo dispositivo (/home, /var/log…) pero no en /proc, /tmp,
/boot ni en discos externos. Devuelve un árbol podado en JSON:

  {"n": nombre, "s": bytes, "d": 1 si es carpeta, "c": [hijos],
   "p": 1 si los hijos no se guardaron (carpeta pequeña: se escanea al entrar),
   "o": N si es el grupo "N elementos más", "e": 1 si hubo carpetas sin permiso,
   "k": número de elementos dentro}

Uso: scan.py [--path DIR] [--out FICHERO]   (sin --out escribe en stdout)
     scan.py --mounts   lista los discos montados que se pueden explorar
"""
import argparse
import json
import os
import stat
import sys
import time

MAX_CHILDREN = 60        # hijos guardados por carpeta (el resto, agrupados)
EXPAND_FRACTION = 1 / 4000  # carpetas más pequeñas que esto no guardan hijos
MAX_DEPTH_STORED = 40


def mount_table():
    """{punto de montaje: dispositivo} de /proc/self/mountinfo."""
    mounts = {}
    try:
        with open("/proc/self/mountinfo") as f:
            for line in f:
                parts = line.split()
                sep = parts.index("-")
                target = parts[4].replace("\\040", " ")
                source = parts[sep + 2]
                mounts[target] = source
    except OSError:
        pass
    return mounts


def fs_source(path, mounts):
    best = ""
    for target in mounts:
        if (path == target or path.startswith(target.rstrip("/") + "/")) and len(target) > len(best):
            best = target
    return mounts.get(best, ""), best


class Scanner:
    def __init__(self, root):
        self.root = root
        self.mounts = mount_table()
        self.source, self.mount_point = fs_source(root, self.mounts)
        # Montajes que NO son del mismo dispositivo: no se entra en ellos.
        self.skip = {t for t, s in self.mounts.items() if s != self.source and t != "/"}
        self.seen_inodes = set()
        self.errors = 0
        self.items = 0

    def walk(self, path):
        """Devuelve (tamaño, nodo completo con todos los hijos)."""
        node = {"n": os.path.basename(path.rstrip("/")) or "/", "s": 0, "d": 1, "c": [], "k": 0}
        try:
            it = os.scandir(path)
        except OSError:
            self.errors += 1
            node["e"] = 1
            return node
        with it:
            for entry in it:
                self.items += 1
                try:
                    st = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    full = entry.path
                    if full in self.skip:
                        continue
                    child = self.walk(full)
                    child["s"] += st.st_blocks * 512
                else:
                    if st.st_nlink > 1:
                        key = (st.st_dev, st.st_ino)
                        if key in self.seen_inodes:
                            continue
                        self.seen_inodes.add(key)
                    child = {"n": entry.name, "s": st.st_blocks * 512}
                    if stat.S_ISLNK(st.st_mode):
                        child["l"] = 1
                node["c"].append(child)
                node["s"] += child["s"]
                node["k"] += 1 + child.get("k", 0)
                if child.get("e"):
                    node["e"] = 1
        return node


def prune(node, threshold, depth=0):
    kids = node.get("c")
    if kids is None:
        return node
    if depth > 0 and (node["s"] < threshold or depth >= MAX_DEPTH_STORED):
        del node["c"]
        if kids:
            node["p"] = 1
        return node
    kids.sort(key=lambda c: c["s"], reverse=True)
    kept = kids[:MAX_CHILDREN]
    rest = kids[MAX_CHILDREN:]
    for child in kept:
        prune(child, threshold, depth + 1)
    if rest:
        kept.append({"n": "", "s": sum(c["s"] for c in rest), "o": len(rest)})
    node["c"] = kept
    return node


def list_mounts():
    """Un punto de montaje por dispositivo real (/dev/…), legible por nosotros."""
    by_source = {}
    for target, source in mount_table().items():
        if not source.startswith("/dev/") or source.startswith("/dev/loop"):
            continue
        if not os.access(target, os.R_OK | os.X_OK):
            continue
        if source not in by_source or len(target) < len(by_source[source]):
            by_source[source] = target
    out = []
    for source, target in sorted(by_source.items(), key=lambda kv: (kv[1] != "/", kv[1])):
        try:
            sv = os.statvfs(target)
        except OSError:
            continue
        out.append({"path": target, "source": source,
                    "size": sv.f_blocks * sv.f_frsize,
                    "used": (sv.f_blocks - sv.f_bfree) * sv.f_frsize,
                    "free": sv.f_bavail * sv.f_frsize})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", default="/")
    ap.add_argument("--out", default="")
    ap.add_argument("--mounts", action="store_true")
    args = ap.parse_args()

    if args.mounts:
        sys.stdout.write(json.dumps(list_mounts(), ensure_ascii=False))
        return

    root = os.path.realpath(os.path.expanduser(args.path))
    started = time.time()
    scanner = Scanner(root)
    tree = scanner.walk(root)
    try:
        tree["s"] += os.lstat(root).st_blocks * 512
    except OSError:
        pass
    prune(tree, tree["s"] * EXPAND_FRACTION)
    tree["n"] = root

    result = {"path": root, "tree": tree, "scannedAt": int(time.time()),
              "seconds": round(time.time() - started, 1), "errors": scanner.errors,
              "items": scanner.items, "mount": scanner.mount_point}
    # Espacio del sistema de ficheros, para el "sin acceso / sistema".
    if root == scanner.mount_point:
        try:
            sv = os.statvfs(root)
            result["fsSize"] = sv.f_blocks * sv.f_frsize
            result["fsUsed"] = (sv.f_blocks - sv.f_bfree) * sv.f_frsize
            result["fsFree"] = sv.f_bavail * sv.f_frsize
        except OSError:
            pass

    data = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
    if args.out:
        out = os.path.expanduser(args.out)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        tmp = out + ".tmp"
        with open(tmp, "w") as f:
            f.write(data)
        os.replace(tmp, out)
    else:
        sys.stdout.write(data)


if __name__ == "__main__":
    main()
