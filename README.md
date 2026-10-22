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
├── julss-flatpak               # Abre el gestor Flatpak (julss.flatpak); con un fichero, lo instala (lo usa Archivos)
├── julss-flatpak-install       # Instalar → Flatpak (fzf sobre Flathub)
├── julss-flatpak-remove        # Desinstalar → Flatpak
└── julss-menu-keybindings     # Super+K: menú de atajos en castellano (traduce el de Omarchy con omarchy/extensions/keybindings-es.tsv)
chromium/chromium-flags.conf    # ~/.config/chromium-flags.conf — Wayland + decodificación de vídeo por hardware
bash/bashrc                     # ~/.bashrc — carga ble.sh (autosugerencias tipo fish)
plugins/                        # Plugins propios de la barra (~/.config/omarchy/plugins/)
├── julss.agents/               # Panel de uso de agentes de IA, en castellano
├── julss.bluetooth/            # Panel Bluetooth, en castellano
├── julss.clipboard/            # Historial del portapapeles, en castellano
├── julss.dropbox/              # Panel Dropbox, en castellano
├── julss.emojis/               # Selector de emojis, en castellano
├── julss.forcequit/            # Copia en castellano de rogergdot.forcequit (MIT, Gregor Oppitz)
├── julss.indicators/           # Indicadores (dictado, grabación, luz nocturna, webcam, teclado: brillo y disposición…), en castellano
├── julss.keyboard-layout/      # Distribución de teclado (clon, sin textos propios)
├── julss.reminders/            # Recordatorios, en castellano
├── julss.speedtest/            # Test de velocidad, en castellano
├── julss.system-update/        # Aviso de actualizaciones, en castellano
├── julss.tray/                 # Bandeja del sistema, en castellano
├── julss.weather/              # Tiempo en castellano + ubicación automática sin Google (Wi-Fi recordada → BeaconDB/OSM → IP) o manual
├── julss.wifiqr/               # QR de la Wi-Fi, en castellano
├── julss.audio/                # Panel Sonido en castellano + sección APLICACIONES siempre visible (volumen y silencio por app)
├── julss.clock/                # Reloj con segundos + calendario, en castellano (locale es_ES); el panel se ensancha con meses largos
├── julss.lan/                  # Red local: escanea la LAN (ping + vecinos + mDNS/DNS/NetBIOS/UPnP) y lista dispositivos con nombre, IP y fabricante
├── julss.disk/                 # Almacenamiento: reparto del disco en queso, anillos, mapa o árbol, navegando por carpetas (clic en DISCO del monitor)
├── julss.flatpak/              # Gestor Flatpak: instaladas (permisos, datos, desinstalar), actualizaciones, buscar en Flathub e instalar .flatpak/.flatpakref/.flatpakrepo abiertos desde Archivos
├── julss.menu/                 # Menú/launcher propio
├── julss.notifications/        # Historial + "Borrar todas", no molestar y selector de tiempo en pantalla (3/5/8/15/30 s/∞)
├── julss.notifications-service/ # Clon del servicio omarchy.notifications que lee ~/.local/state/omarchy/notifications-duration
├── julss.monitor/              # Panel Pantalla en castellano + botón que abre Distribución de pantallas (Monitor Layout, flotante y centrado)
├── julss.power/                # Panel Batería en castellano + salud (capacidad máx. / de diseño, %); icono (no la cifra) verde ≥66 %, amarillo 20–65 %, rojo <20 %
├── julss.network/              # Panel Wi-Fi/red en castellano + IP pública (vía api.ipify.org) + botón ↻ discreto para reiniciar la wifi
├── julss.places/               # Marcadores de Nautilus + expulsar unidades extraíbles
└── julss.workspaces/           # Escritorios sin huecos en la numeración; el activo como cuadrado relleno con el número
patches/
└── monitor-layout-es.patch     # Traducción al castellano del plugin de terceros Monitor Layout (ver abajo)
system/                         # Ficheros de sistema (install.sh pregunta antes de instalarlos con sudo)
├── etc/modprobe.d/blacklist-facetimehd.conf          # La webcam arranca con el driver sin cargar
├── etc/modprobe.d/mbp12-woofers.conf                 # Carga el patch de HDA que reactiva los woofers
├── etc/systemd/system/thunderbolt-aspm.service      # Aplica thunderbolt-aspm al arrancar y al despertar
├── usr/lib/firmware/hda-mbp12-woofers.fw            # Patch HDA: restaura el pin 0x13 (woofers) del CS4208
├── usr/lib/systemd/system-sleep/facetimehd-sleep.sh # Descarga el driver de la webcam antes de suspender
├── usr/lib/systemd/system-sleep/julss-wifi-resume   # Hook al despertar de la suspensión
├── usr/local/bin/facetimehd-aspm-set.sh             # Ajusta ASPM en el enlace PCIe de la webcam
├── usr/local/bin/facetimehd-camera-off.sh           # Webcam: descarga el driver y reactiva ASPM
├── usr/local/bin/facetimehd-camera-on.sh            # Webcam: carga el driver y desactiva ASPM
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

El firmware del BCM43602 a menudo vuelve colgado de la suspensión (S3), así que
el hook `julss-wifi-resume` descarga `brcmfmac` (y `brcmfmac_wcc`) antes de
suspender y, al despertar, hace un reset PCI de la tarjeta y lo carga limpio.

Además, al volver a veces el primer intento de conexión caduca. `julss-wifi-resume-check` espera 30 s; si la wifi no
ha vuelto (y está encendida y hay una red guardada al alcance), reinicia la radio
y, si aun así no conecta, resetea la tarjeta: descarga el driver (primero
`brcmfmac_wcc`, que lo mantiene «en uso»), hace un reset PCI del dispositivo y lo
vuelve a cargar; si el driver no se deja descargar, quita el dispositivo del bus
PCI y lo redescubre. Si el log del kernel muestra el firmware colgado
(`brcmf_msgbuf_query_dcmd: Timeout`, `Failed to reserve space in commonring`) se
salta el reinicio de radio, que en ese caso no sirve. Lo instala `install.sh` (parte de
ficheros de sistema). Si el escaneo no ve ninguna red, lo trata como wifi rota
(es lo que pasa cuando el driver se queda sordo), no como «no hay redes».

Si aun así no vuelve, el botón ↻ tenue del panel Wi-Fi (`julss.network`, junto
al QR) lanza `pkexec julss-wifi-resume-check --force`: sin esperar ni
comprobar, reinicia la radio y, si hace falta, resetea la tarjeta. Si se pulsa
dos veces, la segunda espera a que acabe la primera. El resultado
llega como notificación. A mano: `sudo julss-wifi-resume-check --force`.

Registro: `journalctl -u julss-wifi-resume-check`.

## Webcam FaceTime HD

El driver `facetimehd` no viene en el kernel; se instala desde AUR:

```bash
yay -S facetimehd-dkms facetimehd-firmware
```

Con el driver cargado y ASPM desactivado (necesario para que la imagen salga
sin artefactos) la CPU no llega a sus C-states profundos, así que por defecto
está **desactivado**: `blacklist-facetimehd.conf` evita que se cargue al
arrancar y `facetimehd-sleep.sh` lo descarga antes de suspender.

El indicador *Webcam* de `julss.indicators` (centro de la barra) lo cambia con
un clic (con `pkexec`, pide contraseña). Desactivada se oculta como los demás
indicadores inactivos (aparece oscura al pasar el ratón); activada queda fija
en blanco, y en verde mientras alguna app usa la cámara.

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

## Calculadora científica (`apps/julss-calc`)

Sustituye a `omacalc` (Super+Ctrl+Q y tecla Calculadora). Es C++17 + Qt6 Widgets,
con [Giac](https://www-fourier.ujf-grenoble.fr/~parisse/giac.html) (paquete `giac`)
como motor simbólico en un hilo aparte; arranca en ~0,3 s y no gasta CPU en reposo.

- **Científica**: fórmulas maquetadas, vista previa, grados/radianes, cifras,
  variables y funciones (`a = 5`, `f(x) = x²+1`, `ans`), complejos en forma
  binómica/polar/trigonométrica/exponencial. Acepta `sen`, `tg`, `raiz`, `30°`, `sen x`.
- **Ecuaciones**: ecuaciones (también trigonométricas con n ∈ ℤ y numéricas),
  sistemas lineales con clasificación SCD/SCI/SI, no lineales, inecuaciones como
  intervalos y regiones del plano con vértices, todo con gráfica.
- **Cálculo**: derivadas (parciales), primitivas, integrales definidas y dobles,
  límites (laterales), Taylor, sumatorios, gradiente/hessiana/puntos críticos.
- **Gráficas**: y = f(x), implícitas, regiones, paramétricas 2D/3D, superficies
  z = f(x,y), superficies implícitas F(x,y,z) = 0 (marching tetrahedra +
  z-buffer propio) y funciones complejas f(z) con coloreado de dominio.

`install.sh` instala `giac` y `cmake`, compila e instala en `~/.local/bin`, copia
`share/applications/julss-calc.desktop` y un `omacalc.desktop` con
`NoDisplay=true` (bórralo para volver a ver omacalc en el lanzador). La regla de
ventana flotante está en `hypr/hyprland.lua` y los atajos en `hypr/bindings.lua`.

Para desarrollar: `cmake -S apps/julss-calc -B apps/julss-calc/build && cmake --build apps/julss-calc/build`;
`--target castest` compila un banco de pruebas de consola del motor
(`./build/castest`, o `./build/castest "expr" …`).

## Reproductor de música Sonata

Vive en su propio repositorio: **[julssvanderhaack/sonata](https://github.com/julssvanderhaack/sonata)**
(código, instrucciones y [zip con el ejecutable](https://github.com/julssvanderhaack/sonata/releases)).
Sustituye a Audacious: C++20 + Qt6, FFmpeg y PipeWire, letras sincronizadas,
ecualizador, espectro y los colores del tema de Omarchy.

`install.sh` lo clona (o actualiza) en `~/src/sonata`, lo compila para esta CPU,
lo instala en `~/.local` y lo asocia a los tipos de audio. Aquí sigue
`pipewire/10-julss-native-rates.conf`, que hace que PipeWire respete la frecuencia
de cada canción. Para volver a Audacious:
`xdg-mime default audacious.desktop audio/mpeg audio/flac …`.

## Explorador de archivos Luna

Vive en su propio repositorio: **[julssvanderhaack/luna](https://github.com/julssvanderhaack/luna)**
(código, instrucciones y [zip con el ejecutable](https://github.com/julssvanderhaack/luna/releases)).
Alternativa a Nautilus en C++17 + Qt6, con el nombre y el icono de Luna, la gata
siamesa, y los colores del tema de Omarchy.

`install.sh` instala las dependencias, lo clona (o actualiza) en `~/src/luna`, lo
compila para esta CPU y lo instala en `~/.local`. No lo pone como explorador
predeterminado; para hacerlo: `xdg-mime default luna.desktop inode/directory`.

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
omarchy plugin add https://github.com/stappmus/Omarchy-Spotify               # quickshell.spotify
omarchy plugin add https://github.com/RogerGdot/omarchy-forcequit            # rogergdot.forcequit
omarchy plugin add https://github.com/CJgarcia1229/omarchy-monitor-layout    # io.github.cjgarcia1229.monitor-layout
omarchy plugin add https://github.com/egoist/omarchy-cpu-usage               # dev.egoist.cpu-usage
omarchy plugin add https://github.com/egoist/omarchy-memory-usage            # dev.egoist.memory-usage
omarchy plugin add https://github.com/egoist/omarchy-network-throughput      # dev.egoist.network-throughput
```

Y los temas de terceros que tenía instalados:

```bash
omarchy theme install https://github.com/JJDizz1L/aetheria
omarchy theme install https://github.com/pkovzz/omarchy-black-sand-theme
omarchy theme install https://github.com/bjarneo/omarchy-monokai-theme
omarchy theme install https://github.com/kyerpotts/omarchy-vulkanite-theme
```

### Monitor Layout en castellano

Tras instalarlo, aplicar la traducción y reinstalar su entrada de escritorio:

```bash
cd ~/.config/omarchy/plugins/io.github.cjgarcia1229.monitor-layout
git apply ~/omarchy_a1502_julss/patches/monitor-layout-es.patch
./install-app.sh
```

Si el plugin se ha actualizado y el parche ya no aplica, hay que retraducir:
son solo textos de `monitor_layout.py`, `manifest.json` y el `.desktop.in`.

### Nota sobre el plugin Alt+Tab (`vbrosseau.alttab`)

Necesita que su `alttab-bindings.lua` esté incluido desde
`~/.config/hypr/bindings.lua` (ya está en el `hypr/bindings.lua` de este repo):

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/vbrosseau.alttab/omarchy-plugin/alttab-bindings.lua")
```

Sin eso, el plugin muestra una notificación de error porque no encuentra su
keybinding.
