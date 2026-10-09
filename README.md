# omarchy_a1502_julss

Mis configuraciones y plugins propios para [Omarchy](https://omarchy.org/),
pensados para restaurar rápidamente el setup en una instalación nueva.

## Qué hay aquí

```
hypr/                           # ~/.config/hypr/ (overrides personales, no los defaults de Omarchy)
omarchy/
├── shell.json                  # ~/.config/omarchy/shell.json — layout de la barra
└── extensions/omarchy-menu.jsonc  # ~/.config/omarchy/extensions/omarchy-menu.jsonc
bin/                            # ~/.local/bin/ — scripts usados por el menú
├── julss-flatpak-install       # Instalar → Flatpak (fzf sobre Flathub)
└── julss-flatpak-remove        # Desinstalar → Flatpak
chromium/chromium-flags.conf    # ~/.config/chromium-flags.conf — Wayland + decodificación de vídeo por hardware
bash/bashrc                     # ~/.bashrc — carga ble.sh (autosugerencias tipo fish)
plugins/                        # Plugins propios de la barra (~/.config/omarchy/plugins/)
├── julss.agents/               # Panel de uso de agentes de IA, en castellano
├── julss.bluetooth/            # Panel Bluetooth, en castellano
├── julss.clipboard/            # Historial del portapapeles, en castellano
├── julss.dropbox/              # Panel Dropbox, en castellano
├── julss.emojis/               # Selector de emojis, en castellano
├── julss.forcequit/            # Copia en castellano de rogergdot.forcequit (MIT, Gregor Oppitz)
├── julss.indicators/           # Indicadores (dictado, grabación, luz nocturna…), en castellano
├── julss.keyboard-layout/      # Distribución de teclado (clon, sin textos propios)
├── julss.reminders/            # Recordatorios, en castellano
├── julss.speedtest/            # Test de velocidad, en castellano
├── julss.system-update/        # Aviso de actualizaciones, en castellano
├── julss.tray/                 # Bandeja del sistema, en castellano
├── julss.weather/              # Tiempo en castellano + ubicación automática sin Google (Wi-Fi recordada → BeaconDB/OSM → IP) o manual
├── julss.wifiqr/               # QR de la Wi-Fi, en castellano
├── julss.audio/                # Panel Sonido en castellano + sección APLICACIONES siempre visible (volumen y silencio por app)
├── julss.clock/                # Reloj con segundos + calendario, en castellano (locale es_ES)
├── julss.menu/                 # Menú/launcher propio
├── julss.notifications/        # Historial + "Borrar todas", no molestar y selector de tiempo en pantalla (3/5/8/15/30 s/∞)
├── julss.notifications-service/ # Clon del servicio omarchy.notifications que lee ~/.local/state/omarchy/notifications-duration
├── julss.monitor/              # Panel Pantalla en castellano + botón que abre Monitor Layout (flotante y centrado)
├── julss.power/                # Panel Batería en castellano + salud (capacidad máx. / de diseño, %)
├── julss.network/              # Panel Wi-Fi/red en castellano + IP pública (vía api.ipify.org)
├── julss.places/               # Marcadores de Nautilus + expulsar unidades extraíbles
└── julss.workspaces/           # Escritorios sin huecos en la numeración; el activo como cuadrado relleno con el número
system/                         # Ficheros de sistema (install.sh pregunta antes de instalarlos con sudo)
├── etc/modprobe.d/mbp12-woofers.conf                 # Carga el patch de HDA que reactiva los woofers
├── etc/systemd/system/thunderbolt-aspm.service      # Aplica thunderbolt-aspm al arrancar y al despertar
├── usr/lib/firmware/hda-mbp12-woofers.fw            # Patch HDA: restaura el pin 0x13 (woofers) del CS4208
├── usr/lib/systemd/system-sleep/julss-wifi-resume   # Hook al despertar de la suspensión
├── usr/local/bin/julss-wifi-resume-check            # Comprueba/recupera la wifi tras despertar
└── usr/local/bin/thunderbolt-aspm                   # Activa ASPM L1 en el enlace del Thunderbolt 2
```

Solo se guarda lo propio: configuración personal y plugins con prefijo `julss.*`
escritos por mí. No incluye plugins ni temas de terceros (ver abajo), para no
duplicar código/licencias ajenas ni quedarme con copias desactualizadas.

## Instalar en una máquina nueva

```bash
git clone https://github.com/julssvanderhaack/omarchy_a1502_julss.git
cd omarchy_a1502_julss
./install.sh
omarchy restart shell
hyprctl reload
```

`install.sh` copia (no enlaza) cada fichero a su sitio bajo `~/.config/` (y los scripts de `bin/` a `~/.local/bin/`),
haciendo backup con timestamp de lo que ya exista.

## Autosugerencias en bash (ble.sh)

`bash/bashrc` carga [ble.sh](https://github.com/akinomyoga/ble.sh) si está instalado
(sugerencias en gris desde el historial; → o Ctrl+F acepta, Alt+F acepta una palabra).
Hace falta la versión git, la estable 0.3 no trae autosugerencias:

```bash
yay -S blesh-git
```

## Wifi al despertar (BCM43602)

Al volver de la suspensión, `brcmfmac` recarga el firmware y a veces el primer
intento de conexión caduca. `julss-wifi-resume-check` espera 30 s; si la wifi no
ha vuelto (y está encendida y hay una red guardada al alcance), reinicia la radio
y, si aun así no conecta, recarga el driver. Lo instala `install.sh` (parte de
ficheros de sistema).

Registro: `journalctl -u julss-wifi-resume-check`.

## Vídeo en Chromium (VA-API + H.264)

La GPU (Iris 6100, Broadwell) solo decodifica por hardware H.264 y VP8. YouTube
sirve VP9/AV1, que acaban en la CPU: más consumo, calor y tirones a 1080p60.

- `chromium-flags.conf` añade `AcceleratedVideoDecodeLinuxGL` y
  `AcceleratedVideoDecodeLinuxZeroCopyGL` a la (única) línea `--enable-features=`.
  Chromium solo respeta el último `--enable-features`, así que no hay que
  añadir otra línea.
- Instalar la extensión
  [enhanced-h264ify](https://chrome.google.com/webstore/detail/enhanced-h264ify/omkfmpieigblcllmkgbflkikinpkodlk),
  que obliga a YouTube a servir H.264 (máx. 1080p).

Comprobar: en YouTube, *Estadísticas para nerds* → Codecs debe decir `avc1`;
`chrome://gpu` → Video Decode: *Hardware accelerated*.

## Altavoces: woofers (CS4208)

El kernel aplica al MacBookPro12,1 el fixup del MacBook Air (PCI SSID
8086:7270), que desactiva el pin 0x13 del codec CS4208: solo suenan los
tweeters y el sonido queda metálico
([omarchy#12217](https://github.com/omacom/omarchy/issues/12217)).
`hda-mbp12-woofers.fw` restaura el valor de BIOS (`0x13 0x90100112`) y
`mbp12-woofers.conf` hace que `snd_hda_intel` lo cargue. Lo instala
`install.sh`; se aplica tras reiniciar. Comprobar:

```bash
journalctl -k -b | grep line_outs   # debe listar 0x12/0x13
```

Aparece además un control "Bass Speaker" en el mezclador.

## Ahorro de energía: ASPM en el Thunderbolt 2

El kernel deja desactivado ASPM en el enlace PCIe del controlador Thunderbolt 2
(Falcon Ridge) aunque ambos extremos lo soportan. Con ese enlace siempre
despierto el paquete no baja de PC3, y la CPU gasta ~4 W en reposo. Con
`thunderbolt-aspm` (L1 vía `setpci` en 07:00.0, 06:00.0, 05:00.0 y 00:1c.4)
llega a PC6 y ahorra ~1 W. PC6 es el techo: el panel no tiene PSR.

Lo instala `install.sh` y activa `thunderbolt-aspm.service`, que se ejecuta al
arrancar y al volver de la suspensión. Comprobar:

```bash
lspci -vvs 00:1c.4 | grep LnkCtl   # debe decir "ASPM L1 Enabled"
```

Si algo conectado por Thunderbolt da problemas:
`sudo systemctl disable --now thunderbolt-aspm` y reiniciar.

## Flatpak

Las entradas *Instalar → Flatpak* y *Desinstalar → Flatpak* del menú necesitan
`flatpak` con el remoto Flathub a nivel de sistema:

```bash
omarchy pkg add flatpak
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

## Plugins y temas de terceros a reinstalar aparte

Estos no viven en este repo — hay que volver a instalarlos:

```bash
omarchy plugin add https://github.com/c4software/hyprland-alttab --enable   # vbrosseau.alttab (Alt+Tab switcher)
omarchy plugin add <url-quickshell.spotify>
omarchy plugin add <url-rogergdot.forcequit>
omarchy plugin add <url-io.github.cjgarcia1229.monitor-layout>
omarchy plugin add <url-dev.egoist.cpu-usage>
omarchy plugin add <url-dev.egoist.memory-usage>
omarchy plugin add <url-dev.egoist.network-throughput>
```

Y los temas de terceros que tenía instalados:

```bash
omarchy theme install <url-aetheria>
omarchy theme install <url-black-sand>
omarchy theme install <url-monokai>
omarchy theme install <url-vulkanite>
```

(Rellena las URLs reales la próxima vez que las tengas a mano — no las tenía
localmente al generar este README.)

### Nota sobre el plugin Alt+Tab (`vbrosseau.alttab`)

Necesita que su `alttab-bindings.lua` esté incluido desde
`~/.config/hypr/bindings.lua` (ya está en el `hypr/bindings.lua` de este repo):

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/vbrosseau.alttab/omarchy-plugin/alttab-bindings.lua")
```

Sin eso, el plugin muestra una notificación de error porque no encuentra su
keybinding.
