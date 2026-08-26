# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/),
versionado según [SemVer](https://semver.org/lang/es/).

## [1.3.0] - 2026-08-26

### Actualizado (stack de plugins homologado)

`plugins/manifest.json` alineado con el profile web real tras verificar las
actualizaciones en el puesto (boot limpio, HTTP 200, peers contra el harness
0.1.1-rc.2):

- `dsh-context` ^0.33.1 · `dshmarket` ^1.31.1 · `dsh-defend` ^0.2.0
- `dsh-test-drive` ^0.3.0 · `dsh-tool-describe-image` ^0.5.1
- `dsh-graphlint` ^0.3.1 · `dsh-lsp-actions` ^0.3.4
- `@akslcw/dsh-negative-ledger` ^0.1.2
- `@perrylink/dsh-skill-pack-security-provider` ^2.2.0
- `@linxin666/dsh-ssh` · `dsh-client-ui-git-graph` · `dsh-client-ui-plugin-manager`
  · `dsh-client-ui-skill-explorer` → ^0.3.5
- `dsh-better-sidebar` ^0.16.1

### Agregado

- `dsh-usage-monitor` ^0.1.1 — dashboard de uso de tokens en Settings → Usage
  (probado en el profile web, boot limpio).
- `@huanlin/dsh-plugin-better-locale` ^0.1.0 — peer nuevo que exige
  `dsh-better-sidebar` 0.16.1; se instala como dependencia (no como bundle).
- `dsh-kimicode-swarm` ^0.1.0 — batch de sub-agentes paralelos estilo Kimi
  (herramienta `swarm_batch` + comando `/swarm` + barra de progreso en vivo).
  Instalado y verificado en el profile web (boot sin errores). Documentado en
  `sessionEventWriters` porque escribe el evento `swarm/progress`.

### Cambiado

- `dsh-doublecheck`: actualizada la razón de exclusión — ya no es por peer
  incompatible (0.9.0 encaja con el harness), sino por decisión del usuario de
  mantenerlo fuera del stack.

## [1.2.0] - 2026-08-25

### Agregado

- `dsh-manage session-backup {scan,create,list,verify}` — resguardo de sesiones
  ante plugins que escriben eventos propios. `scan` clasifica cada sesión en
  `ok`/`at-risk`/`broken` extrayendo el catálogo de tipos del harness instalado
  (48 tipos hoy, con piso de cordura de 20 para no clasificar todo como roto si
  el parseo falla). `create` produce snapshots atómicos verificables
  (`MANIFEST.json` + `CHECKSUMS.sha256` + `vocabulary.json`), fuera de
  `sessions/`. Ninguno de estos subcomandos escribe bajo `sessions/`. Diseño en
  `docs/SESSION-BACKUP-DESIGN.md`.
- `plugins/known-session-event-types.json` — baseline vendorizado; `scan` avisa
  si el catálogo del harness cambió respecto de él.
- `plugins/manifest.json`: clave `sessionEventWriters`, que documenta qué
  paquetes escriben eventos de sesión y por qué el problema **no** se puede
  arreglar parcheando el plugin.

### Notas

- **`Session.append()` descarta el flag `ignorable`** en `dsh-session@0.1.1-rc.2`
  (verificado en `lib/index.js:1444`). Por eso los eventos de plugins nacen sin
  marcar y una sesión que los contiene deja de cargar al desinstalar el plugin.
  El fix existe solo en master del harness. Mientras tanto, `session-backup`
  aporta **visibilidad y copias verificables, no inmunidad**.
- Las filas `text-chunks`/`reasoning-chunks`/`tool-call-chunks` del log son
  **filas de almacenamiento**, no eventos: se expanden a `assistant/chunk` antes
  del chequeo de tipos. Contarlas como eventos clasificaba mal 55 de 71 sesiones.

## [1.1.0] - 2026-08-24

### Corregido

- **Distribución**: `install.sh` solo bajaba `dsh-manage.sh` suelto, pero
  `plugins-install`/`service-install` resuelven `plugins/manifest.json` y los
  patches por ruta relativa al script — siguiendo el one-liner recomendado,
  `plugins-install` fallaba con "manifest no encontrado". Ahora `install.sh`
  clona (o actualiza) el repo completo a `~/.dsh-manage` y deja
  `$PREFIX/dsh-manage` como symlink al script dentro del clon. Nuevo flag
  `--clone-dir`. Requiere `git` en el puesto.
- `dsh-manage.sh`: `DSH_MANAGE_DIR` ahora usa `readlink -f` sobre
  `BASH_SOURCE` — sin eso, invocar el script vía el symlink de `install.sh`
  resolvía `plugins/` contra el dir del symlink (`/usr/local/bin`) en vez de
  contra el repo clonado real (verificado con una prueba mínima; no era solo
  una hipótesis).
- **CI**: los tests de `merge-*.{mjs,py}` corren `node` y `python3+pyyaml`
  directo, pero el workflow no los declaraba — dependía de qué trajera el
  runner por default. Ahora se fijan explícitamente `actions/setup-node` y
  `actions/setup-python` + `pip install pyyaml` antes de los tests.
- README: sección "Requisitos" desactualizada (solo decía `ss` + `npm`) —
  ahora documenta `git`, `node`, `python3`/`pyyaml`, y `systemctl` para el
  watchdog. Método "Manual" corregido (clonar + symlink, no `cp` del script
  suelto).

### Confirmado en réplica real

- El fix de shadowing de `dsh-tools`/`cosmokit`/`dsh-fs` en `dsh-autofix.sh`
  (`service-install`) **es necesario, no solo defensa en profundidad**: se
  había anotado como "probablemente ya no hace falta" desde que
  `pnpm-workspace.yaml` trae `autoInstallPeers:false`. Reapareció en la
  primera réplica real en otro puesto — que YA tenía `autoInstallPeers:false`
  desde antes — inmediatamente después de `plugins-install`, rompiendo el
  tool runtime (`Cannot read properties of undefined (reading 'prepare')`).
  Reparado a mano con el mismo `rm -rf` que ya hace el script. **Corré
  `service-install` justo después de `plugins-install`, no como paso
  opcional postergable** — así el fix se aplica solo en el próximo boot en
  vez de requerir intervención manual si el bug reaparece.
- Confirmado además: el bug de shadowing no es exclusivo de
  `plugins-install` — también lo dispara `dsh plugin add` (CLI estándar),
  en cualquier instalación de plugin. Reforzado el mismo día instalando
  `@linxin666/dsh-client-ui-skill-explorer` vía CLI en un host que ya tenía
  `service-install` activo: el shadowing reapareció pero el `ExecStartPre`
  lo limpió solo en el siguiente `systemctl restart`, sin intervención.

### Agregado (plugin nuevo)

- `@linxin666/dsh-client-ui-skill-explorer` sumado al stack homologado
  (`plugins/manifest.json`) — panel GUI para browsear/activar/desactivar/
  crear/borrar skills por fuente (bundled/project/user/custom/runtime).
  Auditado con `plugin_vet` antes de instalar: PASS 87/100, mismo autor
  (`linxin666`/`dsh-web-ui`) ya auditado con `dsh-ssh` y `dsh-git-graph`.

### Agregado

- `dsh-manage plugins-install [profile]` — instala el stack de ~19 plugins
  homologados (dev/calidad, seguridad, ops, observabilidad) en un profile de
  dsh (default `web`), en `$DSH_HOME/profiles/<profile>` (misma ruta que usa
  el binario `dsh` real). Fuente de verdad declarativa en
  `plugins/manifest.json`; merge-only (nunca overwrite) contra un
  `package.json`/`pnpm-workspace.yaml` ya existente. Prepara `pnpm` con
  `corepack` si falta, corre `pnpm install` + `pnpm approve-builds` solo
  para los addons nativos que lo necesitan (`cpu-features`, `ssh2`,
  `node-pty`), reinicia dsh y verifica boot real: puerto escuchando + grep
  de errores conocidos en el log + confirmado contra un profile de scratch
  real que los 18 plugins quedan `"live"` (no solo que el proceso levantó).
- `dsh-manage service-install` — instala y activa el watchdog systemd
  (`dsh.service`, `Restart=always`) con un `ExecStartPre` defensivo
  (`dsh-autofix.sh`) generado con las rutas reales del puesto. Requiere root.
- `plugins/manifest.json` — manifest versionado del stack de plugins:
  dependencias, bundles, `allowBuilds`, `patchedDependencies` y exclusiones
  documentadas (`dsh-doublecheck` por incompatibilidad de peer-version,
  `dsh-chat-recovery` por instalación no verificada).
- `plugins/patches/` — 3 patches `pnpm patch` versionados: el bugfix de
  schema de `dsh-plugin-verify` (ya existente, ahora empaquetado) y 2
  patches nuevos de traducción chino→inglés para mensajes de usuario
  hardcodeados en `dsh-restart-recover` (mensaje de reanudación tras
  restart) y `dsh-secret-guard` (mensaje de bloqueo de secretos) — ninguno
  de los dos traía alternativa en inglés en la versión publicada.
- `plugins/merge-package-json.mjs` y `plugins/merge-pnpm-workspace.py` —
  helpers de merge idempotente usados por `plugins-install`, testeados por
  separado (idempotencia, no pisar un valor customizado a mano).

### Corregido

- **Crítico**: `DSH_HOME` colisionaba entre dos significados — el directorio
  de trabajo propio de `dsh-manage.sh` (log/pid) y la variable que el
  binario `dsh` real usa para ubicar `profiles/`. Una primera versión de
  `plugins-install` inventó `DSH_PROFILES_HOME` para evitar la colisión,
  pero terminó escribiendo el stack de plugins en un directorio que el
  proceso `dsh web` real nunca lee — validado end-to-end e inicialmente
  reportado como "boot OK" cuando en verdad había booteado el profile vacío
  por defecto. Fix: el directorio de trabajo propio del script se renombró
  a `DSH_MANAGE_HOME`; `DSH_HOME` pasa a significar únicamente la config
  real de `dsh` (`$HOME/.dsh` por default, la misma variable que ya exporta
  el propio harness cuando `dsh-manage` corre desde una sesión de agente
  DSH). Reverificado end-to-end: package.json real con 20 dependencias,
  `GET /dsh-market/installed` confirma los 20 plugins en estado `"live"`.
- `plugins_install()` podía reiniciar por error el `dsh.service` de
  PRODUCCIÓN de otro `DSH_MANAGE_HOME` en el mismo host — `systemctl
  is-enabled` solo confirma que el unit existe, no que gestione la instancia
  correcta. Ahora se compara el `WorkingDirectory` real del unit antes de
  decidir `systemctl restart` vs `stop`/`start` propios.
- `pnpm` (a diferencia de `npm`) no tiene flag `--allow-scripts`; el
  control de scripts nativos se hace vía `pnpm-workspace.yaml`
  (`allowBuilds`/`strictDepBuilds`) + `pnpm approve-builds`.
- `start()` nunca pasaba `--port`/`--no-open` al binario `dsh web` pese a
  documentar `DSH_PORT` como configurable — un puerto distinto de 3080
  arrancaba igual en el default del profile y `wait_for_port` nunca lo
  encontraba.
- `service_install()` no declaraba `Environment=DSH_HOME=...` en el unit de
  systemd, así que el proceso lanzado por systemd usaría su propio default
  en vez del `DSH_HOME` configurado.
- `pnpm-workspace.yaml`: `allowBuilds.better-sqlite3` tenía un placeholder
  de comentario pegado como valor (`"set this to true or false"`) en vez de
  `false` — corregido en el manifest.

## [1.0.0] - 2026-08-22

Primera versión estable. Script de instalación/administración de DeepSeek
Harness (`dsh`), pensado para replicarse en los puestos de desarrollo del
staff, con CI, tests y seguridad auditada (gitleaks, sin datos sensibles).

### Agregado

- `dsh-manage {start|stop|update|status|install}` — ciclo de vida completo
  del servidor web de DSH. El puerto es la autoridad (no el pidfile): un
  pidfile stale nunca se confunde con un proceso vivo tras un crash/reboot.
- `dsh-manage version` — versión de `@deepseek-ai/dsh` instalada.
- `dsh-manage check-update` — compara instalada vs. última publicada en npm;
  `status` incluye un aviso breve de update disponible.
- `dsh-manage --version` / `-V` — versión del propio script de gestión.
- **Bootstrap de Node**: `install` descarga el tarball oficial de
  `nodejs.org` (x86_64/aarch64) y lo extrae si `$DSH_NODE/node` no existe —
  ya no requiere que el puesto tenga Node preinstalado a mano. Idempotente,
  verificado con descarga real.
- `install.sh` — instalador de un comando para puestos nuevos
  (`curl ... | bash`): colores, modo verbose, muestra el plan y pide
  confirmación antes de instalar (no es un `curl|bash` ciego); verifica que
  lo descargado sea un script bash válido antes de escribirlo.
- Instalación aislada en la tree de `node24` del usuario vía `--prefix`, sin
  tocar el `~/.npmrc` compartido con otros servicios del host.
- `--allow-scripts` explícito para los addons nativos que dsh necesita
  (`koffi`, `node-pty`, etc.), sin abrir la puerta a scripts de cualquier
  paquete.
- `update` hace `uninstall` + `install` limpio (no upgrade in-place), evita
  archivos huérfanos entre releases RC de dsh.
- Toda la configuración es overrideable por variables de entorno con
  defaults razonables (`DSH_NODE`, `DSH_HOME`, `DSH_PORT`,
  `DSH_START_TIMEOUT`, `DSH_ALLOW_SCRIPTS`, `DSH_PKG`, `DSH_NPM_CACHE`,
  `DSH_NODE_VERSION`).
- CI de GitHub Actions: `bash -n`, `shellcheck`, batería de tests
  `bats-core`, y **gitleaks** con scan completo del historial (no
  incremental, evita el falso "no leaks" en el primer commit).
- Batería de tests: 15 casos con `bats-core`, cubriendo argumentos, status,
  bootstrap de Node y versión — corridos en cada push.
- Licencia MIT.

### Seguridad

- Auditoría de secretos con gitleaks sobre todo el historial: sin hallazgos
  reales (los positivos iniciales fueron falsos — tokens públicos de
  analytics y fixtures de test).
- Referencias a nombres de servicios internos generalizadas antes de la
  primera publicación (info de infraestructura que no debía quedar en un
  repo público).
- Historial purgado con `git filter-repo` para eliminar la mención residual
  a un servicio interno de los primeros commits.

[1.0.0]: https://github.com/elmaxid/dsh-manage/releases/tag/v1.0.0
