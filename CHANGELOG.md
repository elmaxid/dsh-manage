# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/),
versionado según [SemVer](https://semver.org/lang/es/).

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
