# omarchy_a1502_julss

Mis configuraciones y plugins propios para [Omarchy](https://omarchy.org/),
pensados para restaurar rápidamente el setup en una instalación nueva.

## Qué hay aquí

```
hypr/                           # ~/.config/hypr/ (overrides personales, no los defaults de Omarchy)
omarchy/
├── shell.json                  # ~/.config/omarchy/shell.json — layout de la barra
└── extensions/omarchy-menu.jsonc  # ~/.config/omarchy/extensions/omarchy-menu.jsonc
plugins/                        # Plugins propios de la barra (~/.config/omarchy/plugins/)
├── julss.clock/                # Reloj con formato/verticalFormat personalizados
├── julss.menu/                 # Menú/launcher propio
├── julss.notifications/        # Historial de notificaciones + "Borrar todas"
└── julss.places/                # Marcadores de Nautilus + expulsar unidades extraíbles
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

`install.sh` copia (no enlaza) cada fichero a su sitio bajo `~/.config/`,
haciendo backup con timestamp de lo que ya exista.

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
