#!/usr/bin/env python3
"""Escanea la red local y devuelve JSON con los dispositivos encontrados.

Sin herramientas extra ni root:
  1. ping en paralelo a toda la subred (solo redes de /22 o más pequeñas);
     aunque un equipo no responda al ping, la petición ARP lo deja en la
     tabla de vecinos del kernel.
  2. `ip -j neigh` da IP + MAC de cada vecino.
  3. Nombre: mDNS (avahi-resolve), DNS del router (getent) y NetBIOS
     (nmblookup), lo primero que responda.
  4. Fabricante: /usr/share/hwdata/oui.txt; las MAC aleatorias (móviles con
     privacidad activada) se marcan como tales.
"""

import concurrent.futures as cf
import ipaddress
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

OUI_FILE = "/usr/share/hwdata/oui.txt"
SEEN_FILE = os.path.expanduser("~/.local/state/julss-lan/seen.json")
RECENT_SECONDS = 24 * 3600


def run(cmd, timeout=3):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                             env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"})
        return out.stdout if out.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def default_route():
    data = json.loads(run(["ip", "-j", "-4", "route", "show", "default"]) or "[]")
    if not data:
        return None, None
    return data[0].get("dev"), data[0].get("gateway")


def iface_network(dev):
    data = json.loads(run(["ip", "-j", "-4", "addr", "show", "dev", dev]) or "[]")
    for link in data:
        for addr in link.get("addr_info", []):
            if addr.get("family") == "inet":
                return addr["local"], ipaddress.ip_network(f"{addr['local']}/{addr['prefixlen']}", strict=False)
    return None, None


def ping(ip):
    run(["ping", "-n", "-c", "1", "-W", "1", ip], timeout=3)


def load_oui():
    vendors = {}
    try:
        with open(OUI_FILE, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "(hex)" in line:
                    prefix, _, name = line.partition("(hex)")
                    vendors[prefix.strip().replace("-", ":").lower()] = name.strip()
    except OSError:
        pass
    return vendors


def vendor_for(mac, vendors):
    if not mac:
        return ""
    first = int(mac.split(":")[0], 16)
    if first & 0x02:
        return "MAC aleatoria (móvil u ordenador con privacidad)"
    return vendors.get(mac[:8], "")


def clean(name):
    name = (name or "").strip().rstrip(".")
    for suffix in (".local", ".home", ".lan", ".station"):
        if name.lower().endswith(suffix):
            name = name[: -len(suffix)]
    return name


def name_for(ip):
    out = run(["avahi-resolve", "-a", ip], timeout=2)
    if out.strip():
        parts = out.split()
        if len(parts) >= 2:
            return clean(parts[1]), "mDNS"
    try:
        host = socket.gethostbyaddr(ip)[0]
        if host and host != ip:
            return clean(host), "DNS"
    except OSError:
        pass
    out = run(["nmblookup", "-A", ip], timeout=3)
    for line in out.splitlines():
        line = line.strip()
        if "<00>" in line and "<GROUP>" not in line:
            return clean(line.split()[0]), "NetBIOS"
    return "", ""


def ssdp_names(timeout=2.5):
    """UPnP/SSDP: teles, altavoces, impresoras… anuncian su friendlyName."""
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
           "MAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n").encode()
    locations = {}
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        sock.settimeout(0.5)
        sock.sendto(msg, ("239.255.255.250", 1900))
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, (ip, _) = sock.recvfrom(4096)
            except socket.timeout:
                continue
            for line in data.decode(errors="replace").splitlines():
                if line.lower().startswith("location:"):
                    locations.setdefault(ip, set()).add(line.split(":", 1)[1].strip())
        sock.close()
    except OSError:
        return {}

    def fetch(item):
        ip, urls = item
        for url in sorted(urls):
            try:
                with urllib.request.urlopen(url, timeout=2) as resp:
                    root = ET.fromstring(resp.read())
                for el in root.iter():
                    if el.tag.endswith("friendlyName") and (el.text or "").strip():
                        return ip, el.text.strip()
            except Exception:  # noqa: BLE001
                continue
        return ip, ""

    with cf.ThreadPoolExecutor(max_workers=16) as pool:
        return {ip: name for ip, name in pool.map(fetch, locations.items()) if name}


def main():
    dev, gateway = default_route()
    if not dev:
        print(json.dumps({"error": "Sin conexión de red"}))
        return
    own_ip, net = iface_network(dev)
    if not net:
        print(json.dumps({"error": "La interfaz no tiene IPv4"}))
        return
    if net.num_addresses > 1024:
        print(json.dumps({"error": f"Red demasiado grande para escanear ({net})"}))
        return

    with cf.ThreadPoolExecutor(max_workers=65) as pool:
        upnp_future = pool.submit(ssdp_names)
        list(pool.map(ping, [str(h) for h in net.hosts() if str(h) != own_ip]))
        upnp = upnp_future.result()
    time.sleep(0.5)

    neigh = json.loads(run(["ip", "-j", "-4", "neigh", "show", "dev", dev]) or "[]")
    found = {}
    for n in neigh:
        ip, mac = n.get("dst"), (n.get("lladdr") or "").lower()
        states = n.get("state", [])
        if not ip or not mac or "FAILED" in states or "INCOMPLETE" in states:
            continue
        if ipaddress.ip_address(ip) not in net:
            continue
        found[ip] = mac

    own_mac = ""
    try:
        with open(f"/sys/class/net/{dev}/address") as fh:
            own_mac = fh.read().strip().lower()
    except OSError:
        pass

    vendors = load_oui()
    ips = sorted(set(found) | {own_ip}, key=lambda a: ipaddress.ip_address(a))
    with cf.ThreadPoolExecutor(max_workers=32) as pool:
        names = dict(zip(ips, pool.map(name_for, ips)))

    devices = []
    for ip in ips:
        mac = own_mac if ip == own_ip else found.get(ip, "")
        name, source = names.get(ip, ("", ""))
        if name in ("_gateway", "gateway"):
            name, source = "", ""
        if not name and upnp.get(ip):
            name, source = upnp[ip], "UPnP"
        if ip == gateway and not name:
            name = "Router"
        if ip == own_ip:
            name = name or socket.gethostname()
        devices.append({
            "ip": ip,
            "mac": mac,
            "name": name,
            "nameSource": source,
            "vendor": vendor_for(mac, vendors),
            "self": ip == own_ip,
            "gateway": ip == gateway,
        })

    # Historial por MAC: recuerda nombres y los dispositivos que se durmieron.
    now = int(time.time())
    try:
        with open(SEEN_FILE, encoding="utf-8") as fh:
            seen = json.load(fh)
    except (OSError, ValueError):
        seen = {}
    key_net = str(net)
    online_macs = set()
    for d in devices:
        if not d["mac"]:
            continue
        online_macs.add(d["mac"])
        old = seen.get(d["mac"], {})
        if not d["name"] and old.get("name"):
            d["name"], d["nameSource"] = old["name"], "recordado"
        seen[d["mac"]] = {**{k: d[k] for k in ("ip", "name", "nameSource", "vendor", "self", "gateway")},
                          "network": key_net, "firstSeen": old.get("firstSeen", now), "lastSeen": now}
    recent = []
    for mac, info in seen.items():
        if mac in online_macs or info.get("network") != key_net:
            continue
        if now - int(info.get("lastSeen", 0)) <= RECENT_SECONDS:
            recent.append({**info, "mac": mac})
    recent.sort(key=lambda d: -int(d.get("lastSeen", 0)))
    # Olvida lo que lleva más de 30 días sin aparecer.
    seen = {m: i for m, i in seen.items() if now - int(i.get("lastSeen", 0)) <= 30 * 24 * 3600}
    os.makedirs(os.path.dirname(SEEN_FILE), exist_ok=True)
    tmp = SEEN_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(seen, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, SEEN_FILE)

    print(json.dumps({
        "recent": recent,
        "network": str(net),
        "interface": dev,
        "scannedAt": int(time.time()),
        "devices": devices,
    }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - always answer the panel with JSON
        print(json.dumps({"error": f"Error al escanear: {error}"}))
        sys.exit(0)
