# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/),
versionado según [SemVer](https://semver.org/lang/es/).

## [Unreleased]

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

### Agregado

- `dsh-manage plugins-install [profile]` — instala el stack de ~18 plugins
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
