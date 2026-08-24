# dsh-manage

Instalación y administración de **DeepSeek Harness (dsh)** desde la línea de
comandos. Controla el ciclo de vida del servidor web de DSH — instalar,
iniciar, detener, actualizar y consultar estado — de forma idempotente y
robusta.

Pensado para replicarse en los puestos de desarrollo y operar sobre una
instalación de DSH aislada en la tree de `node24` del usuario.

## Comandos

| Comando                      | Qué hace                                                                 |
|------------------------------|--------------------------------------------------------------------------|
| `install`                    | Instala `@deepseek-ai/dsh` globalmente en la tree de `node24`            |
| `plugins-install [profile]`  | Instala el stack de plugins homologado (dev/seguridad/ops) en un profile — default `web` |
| `service-install`            | Instala el watchdog systemd (`dsh.service`, `Restart=always`) — requiere root |
| `start`                      | Arranca el servidor web si no está escuchando ya (idempotente)           |
| `stop`                       | Detiene el proceso que escucha el puerto                                  |
| `update`                     | `uninstall` + `install` limpio de la última versión y lo deja corriendo   |
| `status`                     | Muestra si algo escucha el puerto, pidfile stale y avisa si hay update    |
| `version`                    | Muestra la versión instalada                                              |
| `check-update`               | Compara la versión instalada vs. la última publicada en npm               |
| `--version`, `-V`            | Versión del propio script de gestión (no la de `dsh`) — ver [CHANGELOG](CHANGELOG.md) |

```
dsh-manage start
dsh-manage status
dsh-manage version
dsh-manage check-update
dsh-manage update
dsh-manage stop
```

### Puesto nuevo, de cero a listo para codear

```bash
dsh-manage install            # bootstrap de Node (si falta) + @deepseek-ai/dsh
dsh-manage plugins-install    # stack de ~18 plugins homologado (profile 'web')
dsh-manage service-install    # watchdog systemd, deja dsh siempre arriba
```

Tres pasos, cada uno idempotente y re-ejecutable solo si el anterior falla —
no hace falta reintentar todo desde cero.

> ⚠️ **Corré `service-install` justo después de `plugins-install`, no lo
> postergues**: el `ExecStartPre` que instala repara una regresión conocida
> de pnpm (shadowing de `@deepseek-ai/{dsh-tools,cosmokit,dsh-fs}`) que
> puede romper el tool runtime justo después de instalar el stack de
> plugins — confirmado en una réplica real, ver CHANGELOG. Sin
> `service-install` todavía puesto, si el bug aparece hay que repararlo a
> mano (`rm -rf` de esas 3 carpetas bajo
> `$DSH_HOME/profiles/<profile>/node_modules/@deepseek-ai/` + reiniciar).

### Instalación sobre un puesto que ya tenía `dsh` a mano

Si el server destino ya tiene `dsh`/`node` instalados en otra ruta (por
ejemplo un paquete del sistema en `/usr/bin`, no la tree aislada de
`node24`), apuntá `DSH_NODE` a esa ruta real **antes** de cada comando para
que `dsh-manage` gestione la instalación existente en vez de armar una
paralela:

```bash
export DSH_NODE=/usr/bin      # o donde vivan los binarios node/dsh reales
dsh-manage plugins-install
dsh-manage service-install
```

`plugins-install` es seguro de correr sobre un profile con plugins ya
instalados a mano: el merge nunca pisa una dependencia existente, solo
agrega lo que falte del manifest. `service-install` sí **sobreescribe sin
preguntar** un `/etc/systemd/system/dsh.service` previo — si ya tenías uno
propio (no creado por `dsh-manage`), hacé un backup manual antes
(`cp /etc/systemd/system/dsh.service /etc/systemd/system/dsh.service.bak`).

### `check-update` y `status`

`check-update` consulta el registry de npm y dice si hay una versión más nueva:

```
instalada:  0.1.1-rc.2
ultima:     0.1.1-rc.3
hay actualizacion disponible (0.1.1-rc.2 -> 0.1.1-rc.3)
corre: dsh-manage update
```

- Sin red o si npm no responde → reporta que no pudo consultar (no falla el script).
- `status` incluye un aviso breve de update disponible, sin hacer ruido si estás al día o sin red.

### `plugins-install`: el stack de plugins homologado

Instala en el profile indicado (default `web`) el conjunto de ~18 plugins
comunitarios evaluados uno por uno en un puesto real — boot limpio
verificado, sin colisiones de `id`, sin texto de usuario en chino sin
traducir. La lista completa y el detalle de cada evaluación están en
[`docs/PLUGIN-HOMOLOGATION.md`](docs/PLUGIN-HOMOLOGATION.md); la fuente de
verdad que consume el comando es [`plugins/manifest.json`](plugins/manifest.json).

```bash
dsh-manage plugins-install          # profile 'web' (default)
dsh-manage plugins-install headless # otro profile
```

Qué hace, en orden:

1. Verifica que `dsh` ya esté instalado (si no, para y sugiere `install` primero).
2. Prepara `pnpm` con `corepack` si no está (`node24` lo trae, pero no lo
   activa hasta la primera vez que hace falta).
3. **Merge, nunca overwrite**: si el profile ya tiene `package.json` /
   `pnpm-workspace.yaml` con plugins instalados a mano, se preservan tal
   cual — el manifest solo agrega lo que falte. Correrlo dos veces es
   seguro (verificado: reinstalar un plugin ya presente no duplica nada).
4. Copia los `.patch` del manifest (`pnpm patch` ya aplicado, versionado)
   sin pisar uno que hayas customizado vos con el mismo nombre de archivo.
5. `pnpm install --allow-scripts` + `pnpm approve-builds` solo para los
   addons nativos que realmente lo necesitan (`cpu-features`, `ssh2`,
   `node-pty` — de `dsh-ssh` y `dsh-better-sidebar`). `better-sqlite3` usa
   su prebuild oficial y nunca se aprueba para compilar.
6. Reinicia dsh (via `systemctl` si `dsh.service` existe, si no via
   `stop`+`start`) y verifica boot real: puerto escuchando + grep de
   `duplicate`/`failed to load`/`EADDRINUSE` en el log — no solo que el
   comando haya salido con código 0.

Tres patches de traducción incluidos (ver `plugins/patches/`): dos plugins
traían mensajes de usuario fijos en chino sin alternativa en inglés
(`dsh-restart-recover`, `dsh-secret-guard`) — se tradujeron a inglés antes
de entrar al manifest, mismo mecanismo `pnpm patch` que el bugfix de
`dsh-plugin-verify`.

Queda **fuera** del stack a propósito: `dsh-doublecheck` (incompatible con
esta build de DSH — peer-version exacto que no resuelve, nunca llega a
activarse) y `dsh-chat-recovery` (evaluado pero no llegó a instalación
completa verificable). El MCP de proyecto (`engram`, `code-review-graph`,
etc.) tampoco entra: es específico de cada puesto, se agrega editando
`cordis.patch.yml` del profile aparte.

### `service-install`: watchdog systemd

Escribe y activa un `dsh.service` (`Restart=always`, reinicia solo en 3s si
el proceso muere) más un `ExecStartPre` defensivo que repara una regresión
conocida de pnpm en cada boot sin fallar nunca el arranque. Requiere root.

```bash
sudo dsh-manage service-install
```

Una vez activo, usar `systemctl {status,stop,restart} dsh.service` en vez
de `dsh-manage {start,stop}` — ambos mecanismos gestionan el mismo puerto y
no hay que mezclarlos.

## Requisitos

- **Linux** con `ss` (iproute2) y `npm`.
- **Correr como el usuario que posee el proceso de DSH** (normalmente `root`):
  la detección de PID usa `ss -ltnp`, que solo expone los pids de los sockets
  sobre los que se tienen permisos.

## Instalación

### One-liner (recomendado para puestos dev)

Baja `dsh-manage.sh` del repo y lo deja en `/usr/local/bin/dsh-manage`:

```bash
curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh | bash
```

El instalador muestra el plan, verifica que lo bajado sea un script bash válido
(shebang) y pide confirmación antes de instalar. Opciones:

| Flag              | Qué hace                                            |
|-------------------|-----------------------------------------------------|
| `-y, --yes`       | No pedir confirmación                               |
| `-v, --verbose`   | Mostrar cada paso en detalle                         |
| `--prefix <dir>`  | Dir de instalación (default `/usr/local/bin`)       |
| `--ref <git-ref>` | Versión/branch/tag a bajar (default `main`)         |
| `--no-color`      | Desactivar colores                                   |

```bash
# silencioso para automatizar
curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh | bash -s -- -y

# inspeccionar antes de ejecutar (más seguro)
curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh -o install.sh
less install.sh
bash install.sh
```

> El instalador **no** instala DSH en sí, solo al gestor. Después corrés
> `dsh-manage install` para instalar `@deepseek-ai/dsh`.

### Manual

```bash
sudo cp dsh-manage.sh /usr/local/bin/dsh-manage
sudo chmod +x /usr/local/bin/dsh-manage
```

Alternativamente, operar directo desde el repo: `./dsh-manage.sh <comando>`.

## Configuración

Todo tiene defaults razonables y se overridea por variables de entorno:

| Variable            | Default                                | Descripción                            |
|---------------------|----------------------------------------|----------------------------------------|
| `DSH_NODE`          | `$HOME/.local/dsh-node/node24/bin`     | Dir de los binarios node/npm/dsh        |
| `DSH_MANAGE_HOME`   | `$HOME/dsh-test`                       | Dir de trabajo, log y pidfile **de este script** |
| `DSH_HOME`          | `$HOME/.dsh`                           | Config real del binario `dsh` (profiles, `cordis.patch.yml`) — **no confundir con `DSH_MANAGE_HOME`** |
| `DSH_PORT`          | `3080`                                 | Puerto donde escucha DSH                |
| `DSH_START_TIMEOUT` | `180`                                  | Segundos a esperar por el puerto        |
| `DSH_ALLOW_SCRIPTS` | lista de addons nativos de dsh          | Paquetes a los que npm permite scripts  |
| `DSH_PKG`           | `@deepseek-ai/dsh`                     | Nombre del paquete npm a instalar        |
| `DSH_NPM_CACHE`     | `$DSH_MANAGE_HOME/.npm-cache`          | Cache de npm para consultas de versión   |
| `DSH_NODE_VERSION`  | `v24.19.0`                             | Versión de Node a descargar si falta     |
| `DSH_MANIFEST`      | `plugins/manifest.json` junto al script | Manifest del stack de plugins a instalar |
| `DSH_PNPM_VERSION`  | `11.22.0`                              | Versión de pnpm a preparar via corepack   |
| `DSH_SERVICE_USER`  | usuario actual                         | Usuario que corre el systemd unit         |

> ⚠️ **`DSH_HOME` vs `DSH_MANAGE_HOME`**: son variables distintas a propósito.
> `DSH_HOME` es la MISMA que usa el binario `dsh` internamente para ubicar
> `profiles/`; `plugins-install` y `service-install` la necesitan igual a la
> del `dsh` real, o instalan los plugins en un lugar que el proceso real
> nunca lee (bug real que hubo acá — ver CHANGELOG). Si corrés `dsh-manage`
> **desde una sesión de agente DSH** el harness ya te exporta
> `DSH_HOME=~/.dsh` en el entorno — dejalo así, es el valor correcto.
> `DSH_MANAGE_HOME` es aparte: el dir de trabajo/log/pid de este script
> nomás, sin relación con la config real de `dsh`.

Ejemplo con otro dir de trabajo y puerto:

```bash
DSH_MANAGE_HOME=/srv/dsh-manage DSH_PORT=3100 dsh-manage start
```

## Cómo funciona

- **El puerto es la autoridad**, no el pidfile. `port_pid()` lee con `ss`
  quién está escuchando en `DSH_PORT`. Un pidfile por sí solo no prueba que
  DSH esté corriendo: tras un reboot o crash el PID puede ser reutilizado
  por otro proceso. El pidfile es solo limpieza extra.
- **Instalación aislada**: `npm install -g --prefix` scoped a la tree de
  `node24`, overrideando por comando el `prefix` fijado en el `~/.npmrc` del
  usuario (que apunta a un Node del sistema demasiado viejo para dsh y que
  comparte otro servicio). Así no se toca la config compartida.
- **Bootstrap de Node**: si `$DSH_NODE/node` no existe (puesto nuevo, sin
  Node instalado todavía), `install` descarga el tarball oficial de
  `nodejs.org` para la arquitectura del equipo (x86_64/aarch64) y lo extrae
  en `$DSH_PREFIX` antes de instalar dsh — sin necesitar nvm/fnm ni Node
  preinstalado. Idempotente: si ya hay un `node` ejecutable, no hace nada.
- **Addons nativos**: `koffi`, `node-pty` y demás traen addons que el guard
  de scripts de npm bloquea salvo que se listen explícitamente con
  `--allow-scripts`.
- **Actualización limpia**: `update` hace `uninstall` + `install` explícitos
  en vez de un upgrade in-place, porque dsh es un RC de versionado rápido
  (breaking changes esperados) y un in-place puede dejar archivos huérfanos.

## Desarrollo

```sh
make check    # bash -n + shellcheck (si está instalado)
make test     # batería de tests con bats-core
```

El CI corre `bash -n`, `shellcheck` y la batería de `bats` en cada push.

## Versión

`dsh-manage --version` muestra la versión del propio script (distinta de la
de `dsh` en sí, ver `dsh-manage version`). Historial de cambios en
[CHANGELOG.md](CHANGELOG.md).

## Licencia

[MIT](LICENSE)
