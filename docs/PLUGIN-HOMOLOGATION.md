# Homologación de plugins — harness especialista en dev

Registro de qué plugins comunitarios de DSH fueron probados en el profile
`web`, si levantan sin romper el boot, y por qué. Protocolo: un plugin a la
vez, `stop` + `start` + verificar log + `curl 127.0.0.1:3080`, revertir al
toque si falla, documentar acá antes de seguir con el próximo.

Reintentar los `FALLA` cada tanto (nueva versión del plugin puede arreglar
el conflicto) y mover a `OK` cuando corresponda.

## Regla: nunca editar `node_modules/<pkg>` a mano para un hotfix

`node_modules/<pkg>/archivo.js` bajo `nodeLinker: hoisted` de pnpm es
frecuentemente un **hard link al store global** (`Links: 2` en `stat`, no un
archivo independiente). Editarlo directo parece funcionar al momento, pero
**cualquier operación de pnpm que recalcule ese paquete** (instalar OTRO
plugin, `--force`, a veces hasta un `add` sin relación aparente) puede
repisarlo silenciosamente con la versión original del store — causó un loop
de crash real en esta sesión (ver `dsh-plugin-verify` abajo).

**Usar siempre `pnpm patch <pkg>@<version>` + `pnpm patch-commit`** en su
lugar: genera un `.patch` versionable en `patches/`, registrado en
`pnpm-workspace.yaml` (`patchedDependencies` — pnpm 11 lo pone ahí, no en
`package.json`), que pnpm reaplica automáticamente en cada instalación.
Verificado que sobrevive a `pnpm install --force`.

## Bootstrap de Node (para réplica en puestos sin Node instalado)

Gap encontrado al evaluar `dsh-negative-ledger`: ni `install.sh` ni
`dsh-manage.sh install()` instalaban Node si el puesto no lo tenía — ambos
asumían `npm`/`node` ya funcionando en `$DSH_NODE`. Confirmado en este mismo
box: Node llegó a mano (tarball `node24.tar.xz` bajado y extraído
manualmente, sin nvm/fnm) — exactamente lo que un puesto nuevo del staff
repetiría a mano si no se automatiza.

**Fix**: `dsh-manage.sh install()` ahora llama `bootstrap_node()` primero —
si `$DSH_NODE/node` no existe, descarga el tarball oficial de nodejs.org
(x86_64/aarch64, versión `$DSH_NODE_VERSION`, default `v24.19.0`) y lo
extrae en `$DSH_PREFIX`, mismo layout que una instalación manual. Idempotente
(no-op si ya hay node). Verificado con descarga real (no solo mocks):
`node --version` tras el bootstrap da la versión esperada. Commit `3afc9a7`,
15/15 tests bats verdes, shellcheck limpio, CI verde.

## Leyenda
- ✅ **OK** — instalado, boot limpio, activo en el profile ahora mismo.
- ✅ **OK (con hotfix local)** — activo y sano, pero requirió un parche manual en `node_modules` (bug del propio paquete publicado); el parche se pierde si se reinstala desde cero.
- ❌ **FALLA** — probado y revertido; motivo documentado.
- ⏳ **PENDIENTE** — seleccionado, todavía no probado.

## Progreso: 23 de ~29 probados (22 limpios + 1 con hotfix), 1 incompatible documentado (dsh-TUI), 4 descartados (dsh-mask, Aegis, dsh-update-checker, dsh-cloud-sync), 1 revertido por precaución (dsh-permission-rules — ver hallazgo abajo). **Ops cerrado. Memoria cerrada. Observabilidad & salud: 4/7 instalados (dsh-context sumado), 1 descartado, 3 opcionales. Extra cerrado (2/2). Núcleo: +dsh-skill-explorer (24/08, post-cierre del stack, ver tabla).**

**Stack considerado completo por el usuario** tras esta tanda (dsh-context + dsh-chat-recovery). Pendientes reales que quedan, todos de baja prioridad/opcionales: Workflow (dsh-task-board/dsh-solo-thinking/dsh-github, nunca evaluados), dsh-code-check (vía github:, no npm), dsh-observe/dsh-fast/dsh-budget (métricas/costo, opcionales), dsh-doublecheck en estado `restart` (activa en el próximo reinicio, no urgente).

Nota: de los 7 candidatos de Observabilidad & salud, se instalaron 3
(dsh-startup-guard, dsh-plugin-clinic, dsh-test-drive) — los directamente
ligados a los problemas reales de esta sesión (crashes). `dsh-cloud-sync` se
instaló y luego **se descartó por decisión del usuario**: su UI/mensajes
están en chino y no son legibles para el usuario — ver tabla de Ops abajo.
Los 4 de métricas/costo (dsh-observe, dsh-fast, dsh-context, dsh-budget)
quedaron como opcionales, sin instalar todavía.

**Confirmado con evidencia real**: reinstalar un plugin ya presente (`dsh plugin --profile web add <pkg-ya-instalado>`) es **idempotente y seguro** — no duplica la entrada en `package.json`/`bundles`, no cambia versión, pnpm solo reutiliza lo ya resuelto en el lockfile, sin tocar el proceso vivo (no hace falta reiniciar). Relevante para el plan de réplica: correr el mismo comando de instalación dos veces en un puesto no rompe nada.

## Seguimiento de consumo (boot time / memoria)

| Punto de medición | # plugins | Boot (Started → server responde) | Memoria (RSS) |
|---|---|---|---|
| Tras Tanda 2 (dev/calidad) | 12 | ~5.4s | ~256 MB |
| Tras dsh-ssh (Ops) | 14 | ~4.76s | ~514 MB |
| Tras dsh-restart-recover (Ops) | 15 | ~7.77s | ~500 MB |
| Tras dsh-negative-ledger (Memoria) | 16 | ~9.14s | ~481 MB |
| Tras dsh-startup-guard (Observ.) | 17 | ~5.63s | ~293 MB |
| Tras dsh-plugin-clinic (Observ.) | 18 | ~6.23s | ~284 MB |
| Tras dsh-test-drive (Observ.) | 19 | ~5.44s | ~282 MB |
| Tras dsh-cloud-sync (Observ.) | 20 | ~5.44s | ~314 MB |

El boot no escala mal con la cantidad de plugins (bajó, no subió). La
**memoria casi se duplicó** al agregar `dsh-ssh` — esperable, trae un addon
nativo (`ssh2`/`cpu-features` compilados) y mantiene un connection pool
persistente. Vigilar en el próximo checkpoint (cada 5-6 plugins) si sigue
esa tendencia o se estabiliza.

## Cómo ver la UI de los plugins instalados

Los plugins sin panel visual (dsh-doublecheck, dsh-lsp-actions, dsh-graphlint,
dsh-plugin-verify, dsh-defend, dsh-skill-pack-security) no requieren ninguna
acción — son tools/skills para el agente. Los que sí tienen UI:

- **dsh-git-graph**: chip de rama junto al selector de workspace, **solo en
  una sesión en blanco** (conversación nueva, antes del primer mensaje);
  desaparece en sesiones activas.
- **dsh-better-sidebar**: panel lateral derecho; **requiere hard refresh del
  navegador** (Ctrl+Shift+R) tras instalar — el bundle JS viejo puede seguir
  cargado en la pestaña.
- **dsh-market / dsh-plugin-manager**: siempre visibles (sidebar / Settings).

Verificación real: `GET /dsh-market/installed` (same-origin) devuelve
`activation.<paquete>.state` — los 10 instalados hasta ahora están todos
`"live"`. El backend confirma que están montados; si no se ven en pantalla,
el problema es del lado del navegador (cache/refresh), no del servidor.

## Desfasaje de peer-version (hallazgo, sin acción requerida)

`dsh-better-sidebar` v0.14.0 (instalada, "latest") declara peer
`@deepseek-ai/dsh-agent: ^0.1.0-rc.8`. Tu DSH real es `0.1.1-rc.2` — que en
calendario es MÁS NUEVA, pero `semver.satisfies('0.1.1-rc.2', '^0.1.0-rc.8')`
da `false` (el rango `^0.1.0-rc.8` con pre-release en la base es muy
estricto). **No hay nada que actualizar**: `0.1.1-rc.2` ya es la `latest`
publicada de `@deepseek-ai/dsh` en npm — no existe una versión más nueva.

Consecuencia observada: el "Creator Mode" que el usuario esperaba seleccionar
**no existe como preset en esta instalación de DSH** — los únicos presets
nativos disponibles son `cordis`, `standard`, `minimal`, `code` (confirmado
listando `.../dsh/config/agent-presets/`). Seleccionarlo y reiniciar no lo
"toma" porque no hay tal preset para tomar; la UI cae al fallback (`standard`).
No es un bug de instalación — es una feature que no está en el canal/versión
de DSH que corre acá. Sin acción pendiente; documentado para no reinvestigar.

## Núcleo

| Plugin | npm | Estado | Notas |
|---|---|---|---|
| dsh-market | `dshmarket` | ✅ OK | App store de plugins. |
| dsh-plugin-manager | `@linxin666/dsh-client-ui-plugin-manager` | ✅ OK | Gestor visual. |
| dsh-skill-explorer | `@linxin666/dsh-client-ui-skill-explorer` | ✅ OK | Instalado 24/08 vía `dsh plugin --profile web add ...` (CLI, no Market UI). Auditado antes con `plugin_vet`: PASS 87/100 (sin scripts install, sin red sospechosa, sin payloads; mismo autor `linxin666`/`dsh-web-ui` ya auditado con `dsh-ssh`/`dsh-git-graph`). Panel GUI: browsear/activar/desactivar/crear/borrar skills por fuente (bundled/project/user/custom/runtime). **Confirmó un hallazgo nuevo sobre el bug de shadowing** (ver `dsh-plugin-verify` abajo): también lo dispara `dsh plugin add` por CLI, no solo `dsh-manage plugins-install` — no es exclusivo de ese comando nuevo. Quedó en `state: "restart"` (no hot-mount) tras el `add`; `systemctl restart dsh.service` disparó el `ExecStartPre` (`dsh-autofix.sh`) que limpió el shadowing solo y activó el plugin en caliente — funcionó tal como está diseñado, sin intervención manual. |
| dsh-better-sidebar | `dsh-better-sidebar` | ✅ OK | Requirió aprobar build nativo de `node-pty` (`pnpm approve-builds node-pty`). |
| dsh-TUI | `@deepseek-harness-tui/dsh-tui` | ❌ FALLA | **No instalar en el profile `web`.** Trae su propio `@dsh-std/storage` empaquetado → colisiona con `id: storage` que ya registra `dsh-base`/`dsh-web-app` → `duplicate loader entry id: storage`, boot no abre el puerto. Es una herramienta de terminal standalone: se instala en su **propio profile** (`dsh plugin --profile dsh-tui add ...`), nunca junto a los plugins de `web`. |

## Dev & calidad

| Plugin | npm | Estado | Notas |
|---|---|---|---|
| dsh-git-graph | `@linxin666/dsh-client-ui-git-graph` | ✅ OK | |
| dsh-doublecheck | `dsh-doublecheck` | ⚠️ OK (boot no rompe, pero desactivado en cada arranque) | Boot no rompe, DSH sano — pero `state: "restart"`/**deshabilitado en cada boot por `dsh-startup-guard`**, no `"live"`. Causa raíz REAL (no es residuo del incidente de dsh-plugin-verify, confirmado): `dsh-doublecheck@0.7.1` exige `@deepseek-ai/dsh-agent@0.1.0-rc.6` (versión EXACTA, sin rango) como peer, y varios otros `@deepseek-ai/*` en esa misma versión. DSH real es `0.1.1-rc.2`. Verificado con `semver.satisfies('0.1.1-rc.2','0.1.0-rc.6')` → `false`. La última versión publicada (`0.7.3`) tampoco resuelve: pide `>=0.1.0-rc.8 <0.2.0`, y `semver.satisfies('0.1.1-rc.2','>=0.1.0-rc.8 <0.2.0')` → `false` también (mismo patrón que `dsh-better-sidebar`: pre-release estricto en el rango). **No hay versión publicada compatible con este DSH.** `dsh-startup-guard` está funcionando correctamente al desactivarlo — no forzar el `disabled: false` a mano en `cordis.patch.yml`, volvería a aparecer solo en el próximo boot (y forzarlo bypaseando el guard arriesga un fallo más sutil en runtime en vez de una desactivación limpia). Grill/guard: sus skills/tools de disciplina de ingeniería NO están activos mientras siga así — usar `dsh-plugin-verify`/`dsh-doublecheck` alternativas o esperar una versión de dsh-doublecheck compatible con rc.2. |
| dsh-graphlint | `dsh-graphlint` | ✅ OK | Requiere además `pip install graphlint` (motor Python) para las tools funcionen de verdad; el plugin npm solo es el wrapper de tools. Pendiente instalar la parte pip. |
| dsh-lsp-actions | `dsh-lsp-actions` | ✅ OK | |
| dsh-plugin-verify | `dsh-plugin-verify` | ✅ OK (con hotfix persistente vía `pnpm patch`) | **Diagnóstico corregido tras verificar contra el paquete real de npm** (`npm pack dsh-plugin-verify@1.0.0`, sin ningún parche): v1.0.0 publicado tiene 2 bugs de schema reales, uno de ellos documentado AL REVÉS en una versión anterior de esta nota (corregido acá): (1) `output.schema` de la raíz trae `required: true` — **inválido, hay que SACARLO** (no agregarlo — la nota vieja decía lo opuesto); el DSL de dsh-tools rechaza `schema.required` a nivel raíz, solo lo acepta por-propiedad; (2) `evidence.items`/`summary` sin `additionalProperties` explícito, que el DSL exige siempre. Ambos causan `JsonSchemaError`/crash del plugin tree al boot. **Incidente real (23/08 ~00:03)**: instalar `dsh-ssh` disparó un recálculo de deps que repisó el hotfix (vivía editado a mano en `node_modules/dsh-plugin-verify/lib/index.js`, que resultó ser un **hard link al store global de pnpm** — `Links: 2`, confirmado con `stat` — CUALQUIER operación de pnpm que tocara ese paquete podía repisarlo, no solo `dsh-ssh`). Loop de crash cada ~9s hasta reaplicar a mano. **Primer intento de fix con `pnpm patch` (incompleto, corregido después)**: generé un patch que solo cubría el bug (2), porque la base que edité con `pnpm patch` ya tenía el bug (1) resuelto por una edición manual previa en la sesión — **verificado con `patch --dry-run` sobre el tarball real de npm que ese primer patch NO resolvía el bug (1)**, hubiera vuelto a romper en una réplica limpia. **Fix definitivo, verificado end-to-end**: regenerado el patch (`pnpm patch` + edit + `pnpm patch-commit`) con AMBOS fixes; aplicado con `patch -p1` sobre el tarball de npm limpio (`npm pack`) para confirmar el resultado correcto sin depender del estado previo del disco. Registrado en `pnpm-workspace.yaml` → `patchedDependencies` (pnpm 11 lo pone ahí, no en `package.json`). Sobrevive `pnpm install --force` y reinicio de DSH, boot limpio. |
| dsh-code-check | no publicado en npm — `github:a179-sanae/dsh-code-check#main` | ⏳ PENDIENTE | Instalar vía spec `github:`, no npm. |

## Seguridad

| Plugin | npm | Estado | Notas |
|---|---|---|---|
| dsh-skill-pack-security | `@perrylink/dsh-skill-pack-security-provider` | ✅ OK | **No tiene UI propia** — no busques nada en el sidebar. Se manifiesta como (1) 8 skills nuevas disponibles para el agente: `dependency-audit`, `incident-response`, `prompt-injection-review`, `secret-scan`, `security-audit`, `supply-chain-review`, `threat-model`, `vuln-intel` (verificado comparando el catálogo de skills antes/después de instalar); (2) la tool `plugin_vet` (scanner de supply-chain) disponible para el agente. Confirmación: pedile al agente "usá la skill secret-scan sobre tal repo". |
| dsh-defend | `dsh-defend` | ✅ OK | Boot limpio tras `systemctl restart dsh.service` (PID 2337534, log sin errores, curl 200). Trajo +31 paquetes de dependencias transitivas, sin conflicto de entry-id. Protección en vivo (no requiere UI): intercepta mensajes/tool-args/tool-results por prompt-injection, jailbreak y secret-leak. |
| dsh-mask | `dsh-mask` | 🚫 DESCARTADO | Decisión del usuario: no le interesa el masking de PII para este harness. No instalar. |
| dsh-secret-guard | `dsh-secret-guard` | ✅ OK | Ojo: NO es `secret-guard` (nombre distinto en npm). Boot limpio tras `systemctl restart dsh.service` (PID 2710719, log sin errores, curl 200). Sin UI propia: bloquea leer/escribir archivos sensibles (`.env`, credenciales, keys) + audit journal. |
| dsh-plugin-gate | `dsh-plugin-gate` | ✅ OK | Boot limpio tras `systemctl restart dsh.service` (PID 3414515, log sin errores, curl 200). Sin UI propia: scanner tipo antivirus de install scripts/permisos antes de `dsh plugin add` — mismo tipo de gate que `mcp__dog_trial__peasant_plugin_vet` usado en esta sesión, ahora nativo al harness. |
| dsh-guardian | `dsh-guardian` | ✅ OK | Versión `0.1.0-alpha.2` — pre-release, pero boot limpio tras `systemctl restart dsh.service` (PID 3723897, log sin errores, curl 200). Sin UI propia: intercepta y audita cada tool call, pide confirmación en operaciones sensibles. |
| dsh-permission-rules | `dsh-permission-rules` | ❌ FALLA (revertido por precaución) | Boot inicial limpio (PID 111197, curl 200), y confirmado activo por el propio runtime context de la sesión. **Efecto colateral real detectado**: el proxy de red que instala (`127.0.0.1:<puerto>`) intercepta TODO tráfico saliente de subprocesos hijos del proceso `dsh web` — incluida esta sesión de agente (bash de Claude Code es hijo directo de `dsh web` en este setup), bloqueando `npm view` con 403 aun en modo `auto`/sandbox `danger-full-access`. **Riesgo más serio, documentado por el propio autor**: el plugin escribe eventos `permissionRules/decision`/`permissionRules/network` al historial de sesión con un "adaptive ignorable gate" — detecta si el host honra el marker `ignorable:true` y se auto-desactiva si no, pero el propio código (`lib/index.js:2797`) admite que en hosts donde `Session.append` "predates the ignorable marker" las sesiones quedan `SessionFormatUnsupportedError` (irrecuperables) — issue conocido: `github.com/PerryLink/dsh-permission-rules/issues/2`, con script propio de reparación (`scripts/repair-session-logs.mjs scan\|repair`). **Verificado en este DSH concreto**: escaneando las 26 sesiones existentes con ese script, 0 archivos afectados — el bug no llegó a corromper nada acá (esta versión de DSH sí honra el marker). Aun así, **desinstalado por precaución** (`pnpm remove` + `pnpm install` para limpiar node_modules huérfano, sin reinicio del proceso — no hizo falta, el cambio no toca el árbol de bundles en caliente): el riesgo de historial irrecuperable en un harness de uso diario no se justifica por las reglas de permisos, que se pueden lograr con `dsh-guardian`/`dsh-defend` ya instalados. Reintentar en el futuro si el proyecto corrige el issue #2, o usar con `allowUnmarkedAudit: false` + repair script como rutina si se vuelve a instalar. |

## Memoria (recortado — engram ya cubre persistencia general)

| Plugin | npm | Estado | Notas |
|---|---|---|---|
| dsh-negative-ledger | `@akslcw/dsh-negative-ledger` | ✅ OK | No es memoria (el propio README lo aclara: "Not memory: no positive knowledge, no semantic recall") — no redunda con engram. Graba solo hechos negativos (comando/archivo que falló + evidencia) y avisa/bloquea reintentos idénticos mientras la evidencia no cambie. Usa `better-sqlite3` (addon nativo) — bloqueó con `ERR_PNPM_IGNORED_BUILDS` como `dsh-ssh`, pero el propio README avisa que trae prebuilds oficiales y no hay que compilar: `pnpm config set --location project strict-dep-builds false` en vez de `approve-builds` (que sí compilaría desde código fuente). Verificado que carga con el prebuild `linux-x64` sin compilar (`require('better-sqlite3')(':memory:')` funciona). No escribe eventos propios al historial de sesión (usa `additionalContexts`), sin el riesgo de `dsh-permission-rules`. Boot: `Started` 23:35:11.232 → responde 23:35:20.373 → **~9.14s** (el más lento hasta ahora, sin errores). |

## Workflow

| Plugin | npm | Estado | Notas |
|---|---|---|---|
| dsh-task-board | `dsh-taskboard` | ⏳ PENDIENTE | Ojo: nombre real es `dsh-taskboard`, no `dsh-task-board`. |
| dsh-solo-thinking | `dsh-plugin-solo-thinking` | ⏳ PENDIENTE | |
| dsh-github | `dsh-github` | ⏳ PENDIENTE | |
| Aegis (pack completo) | `aegis` | 🚫 DESCARTADO | Auditado: 13 de 22 skills son copias TEXTUALES (verificado byte a byte con `systematic-debugging`) del plugin `superpowers` que el usuario ya usa en Claude Code. Redundante instalar el pack completo en DSH. Las 2 skills genuinamente nuevas que sí interesan (`anti-entropy-governance`, `long-task-continuation`) se evalúan aparte, copiadas sueltas — ver sección "Skills sueltas pendientes" abajo. |

## Ops

| Plugin | npm | Estado | Notas |
|---|---|---|---|
| dsh-ssh | `@linxin666/dsh-ssh` | ✅ OK | **Ojo crítico**: el nombre npm genérico `dsh-ssh` (sin scope) es de otro autor (`UynajGI/dsh-ssh`), NO auditado. Usar siempre `@linxin666/dsh-ssh` (repo `zhu1090093659/dsh-web-ui`, el que auditamos). Requirió aprobar builds nativos (`pnpm approve-builds cpu-features ssh2`) — compilaron limpio. Boot medido con precisión vía journal: `Started` a systemd 23:03:31.345 → server respondiendo (`dsh web: http://...` en el log) 23:03:36.110 → **~4.76s**, sin errores. Memoria subió de ~256MB (12 plugins) a ~514MB (14 plugins, con addon nativo SSH compilado) — ver nota de consumo abajo. |
| dsh-harness-ops | `@fakechris/dsh-restart-recover` | ✅ OK | El repo es un monorepo; el paquete real es el subpaquete `dsh-restart-recover`. Boot: `Started` 23:05:49.412 → server respondiendo 23:05:57.180 → **~7.77s** (sin errores; un poco más lento que las mediciones previas, sin patrón claro de causa — vigilar). **Confirmado funcionando en vivo, sin buscarlo**: tras el restart de esta instalación, el propio plugin detectó el turno interrumpido de la sesión e inyectó automáticamente el `CONTINUE_MESSAGE` esperado ("检测到上次会话因重启被中断...") — coincide exacto con el código fuente auditado (`src/index.ts`). Complementa el watchdog de systemd: systemd relanza el proceso, este plugin retoma el turno del agente que quedó a mitad de camino. Usa tipos de evento nativos de DSH (`turn/end`/`turn/start`), sin el riesgo de `dsh-permission-rules`. |
| dsh-update-checker | `dsh-update-checker` | 🚫 DESCARTADO | Decisión del usuario tras comparar con `dsh-manage.sh update`. Motivos: (1) solapa funcionalmente — `dsh-manage.sh` ya cubre actualizar el harness; (2) **el propio README admite que el botón de "update con un click" está tuneado para Windows** ("the restart flow spawns PowerShell"; en Linux/macOS "banners and version checks still work, but the update/restart buttons need code adaptation" — soporte de Linux es "the natural next step", no está listo); (3) tiene su propio watchdog de restart (kill by PID + puerto + HTTP probe) que colisionaría con el systemd que ya activamos, mismo tipo de conflicto de doble supervisor que documentamos arriba. Si en el futuro se quiere el aviso de updates de plugins de terceros, hacerlo por fuera (script/skill que compare `npm view <pkg> version` contra lo instalado) en vez de este plugin. |

## Observabilidad & salud

| Plugin | npm | Estado | Notas |
|---|---|---|---|
| dsh-observe | `dsh-observe` | ⏳ PENDIENTE | |
| dsh-fast | `dsh-fast` | ⏳ PENDIENTE | |
| dsh-context | `dsh-context` | ✅ OK | Nombre npm sin scope, verificado: `repository` en npm apunta a `bowenliang123/dsh-context`, mismo autor del `package.json` fuente — sin riesgo de name-squatting. Auditado: gitleaks 0 leaks, sin postinstall/preinstall, sin exec/eval/child_process sospechoso. Boot limpio (PID 3165392, sin errores), confirmado `state: "live"` hot-mounted vía `dsh-market`. Patch de `dsh-plugin-verify` sobrevivió esta instalación (verificado). Panel de context-insight: qué llena la ventana del modelo y por qué. |
| dsh-budget | `dsh-budget` | ⏳ PENDIENTE | |
| dsh-startup-guard | `dsh-startup-guard` | ✅ OK | Reinstalación probada en vivo con `dsh-defend` antes de este: `dsh plugin add` sobre un paquete ya presente es idempotente (no duplica en `package.json`/bundles, pnpm solo "reused" transitivas, sin tocar versión). Guard de arranque: repara logs de sesión corruptos, snapshot de manifests antes de arrancar, **preflight de composición de bundles** (detecta conflictos de plugin ANTES de que rompan el boot — justo lo que hubiera evitado el caso `dsh-tui`), pone en cuarentena el bundle que crashea. Boot: `Started` 23:43:55.961 → responde 23:44:01.594 → **~5.63s** (más rápido que las últimas mediciones). |
| dsh-plugin-clinic | `dsh-plugin-clinic` | ✅ OK | Boot limpio (PID 1254273, ~6.23s, sin errores). Expone `GET /clinic` (JSON con `schemaVersion`/`environment`/`profiles[].plugins[].findings`) — **verificado real, no solo README**: consultado en vivo, devuelve reporte estructurado de los 20 plugins del profile `web`. **Falso positivo detectado**: reportó `dsh-lsp-actions` como `critical`/"not resolvable from the profile" — verificado que es incorrecto: el paquete existe en disco (`main: lib/index.js`, archivo presente), y `GET /dsh-market/installed` (fuente más confiable, ya auditada) confirma `state: "live"`, activo con bundle patch cargado. Sin impacto real; anotar como bug conocido del clinic si se reporta upstream. El resto de los 8 findings con `warning` son peer-version mismatches esperables (mismo patrón que `dsh-better-sidebar`/rc.8 vs rc.2, no bloquean nada) y "declares install-time script prepare" (informativo, no ejecuta nada extra sin `--allow-scripts`). |
| dsh-test-drive | `dsh-test-drive` | ✅ OK | Boot limpio (PID 1300632, ~5.44s, sin errores). Instala plugins candidatos en un profile descartable (`DSH_HOME` temporal) y devuelve pass/fail estructurado sin tocar el profile real — automatiza el mismo protocolo manual que usamos toda esta sesión (esta misma herramienta, `purse_test_drive`, ya se venía usando desde fuera de DSH para auditar candidatos antes de instalarlos acá). |
| dsh-cloud-sync | `@dickpy/dsh-cloud-sync` | 🚫 DESCARTADO | Se instaló, boot limpio, código auditado sano (node:crypto nativo, tokens nunca en config serializada, excluye .env/.credentials.yaml, cero deps externas) — pero **desinstalado por decisión del usuario**: la UI/mensajes del plugin están en chino, no legibles para el usuario. Sigue siendo el candidato correcto para el punto 5 del plan (réplica multi-equipo) si en algún momento se resuelve el idioma (config `locale`, fork, u otro plugin equivalente en inglés/español) — no descartar la necesidad, solo este paquete puntual. |

## Extra

| Plugin | npm | Estado | Notas |
|---|---|---|---|
| dsh-tool-describe-image | `dsh-tool-describe-image` | ✅ OK | Nombre npm sin scope, correcto tal cual. Mismo repo/autor ya auditado (`zhu1090093659/dsh-web-ui`). Herramienta de visión vía cualquier API OpenAI-compatible + paste-to-describe + mascota de escritorio (cosmético, viene empaquetado junto). Boot limpio, sin errores. |
| dsh-chat-recovery | `@linxin666/dsh-chat-recovery` | ✅ OK | **Ojo**: el nombre genérico `dsh-chat-recovery` sin scope da 404 en npm — usar siempre `@linxin666/dsh-chat-recovery` (mismo repo `zhu1090093659/dsh-web-ui`). Recuperación de turnos fallidos: edición fork + reintento explícito del último turno, preservando la sesión original. Complementa `dsh-restart-recover` (ese reacciona a crashes del proceso; este a turnos que fallan con el proceso vivo). Boot limpio (PID 3179605, sin errores), confirmado `state: "live"` vía dsh-market. Patch de `dsh-plugin-verify` sobrevivió esta instalación (verificado). |

## Skills sueltas pendientes (no son plugins DSH — instalación aparte)

Auditadas, útiles para el puesto de trabajo, pero de mecanismo distinto al de
los plugins `dsh plugin add` de arriba. Sin acción tomada todavía — pendiente
de retomar.

| Item | De dónde | Qué hace | Estado |
|---|---|---|---|
| `anti-entropy-governance` | github.com/GanyuanRan/Aegis (skill suelta, NO el pack completo) | Detecta código muerto / fallbacks duplicados / dueños duplicados de una misma lógica; pide confirmación explícita antes de acciones destructivas de limpieza. | ⏳ Pendiente: confirmar la ruta exacta donde DSH resuelve skills de usuario (no localizada aún en el árbol nativo — no copiar a ciegas). Formato SKILL.md compatible (mismo header `---\nname/description\n---` que usa DSH nativo, verificado). |
| `long-task-continuation` | github.com/GanyuanRan/Aegis (skill suelta) | Mantiene estado de una tarea multi-paso que cruza reinicios de contexto/sesión — evita perder el hilo en trabajos largos (como esta misma sesión de instalación). | ⏳ Pendiente, mismo motivo que arriba. |
| `unlazy` | github.com/Leonxlnx/unlazy (951★, MIT) | Hook `Stop` de **Claude Code** (no DSH): método "Depth Tree", bloquea terminar el turno mientras haya gates sin cumplir en `GATES.md`/`gates/*.md`. Auditado: gitleaks 0 leaks, zero dependencias, zero-token (solo escaneo de archivos, no llama al modelo), nunca traba indefinido (libera tras 6 bloqueos sin progreso), `gate-check.mjs` ejecuta comandos `CHECK:` del propio `GATES.md` del proyecto (mismo modelo de confianza que un Makefile), no del paquete. | 🔖 Candidato para tener en cuenta — es de Claude Code, no entra en la cola de DSH. Instalación: `node scripts/install-hooks.mjs` (o `--global`/`--shared`), idempotente, desinstalable con `--uninstall`. |

## Infraestructura: watchdog de proceso (systemd)

`dsh-manage.sh` levanta el proceso con `nohup` suelto, sin ningún supervisor:
si el proceso muere, queda muerto hasta que alguien corre `start` a mano.
Ya existía un unit `/etc/systemd/system/dsh.service` preparado (enabled pero
inactive) — se activó como capa de watchdog:

```ini
[Service]
Type=simple
User=root
WorkingDirectory=/root/dsh-test
Environment=PATH=/root/.local/dsh-node/node24/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=/root
ExecStart=/root/.local/dsh-node/node24/bin/dsh web
Restart=always
RestartSec=3
StandardOutput=append:/root/dsh-test/dsh.log
StandardError=append:/root/dsh-test/dsh.log
```

**Verificado real**: se mató el proceso (`kill <pid>`) y systemd lo relanzó
solo en 3s (`journalctl -u dsh.service` — "Deactivated successfully" →
"Scheduled restart job" → "Started", sin intervención manual).

**Hallazgo**: el journal mostró un loop de crash previo (madrugada del
22/08, restart counter llegó a 1166, ~4s entre intentos) — coincide en
tiempo con el problema de pnpm/PATH que resolvimos por separado (ver symlink
abajo). Probablemente la causa del loop viejo era la misma.

**Fix de PATH para pnpm**: el proceso de `dsh web` (vía systemd o vía
`dsh-manage.sh`) solo busca binarios en `/root/.local/dsh-node/node24/bin`
(el `DSH_NODE` del script). pnpm se había instalado en un prefix separado
(`/root/.local/dsh-node/bin`, para no tocar la tree de owner `mke`), así que
el proceso nunca lo encontraba (`dsh: pnpm not found on PATH` en el Market).
Fix: symlink dentro del PATH real del proceso —

```bash
ln -sf /root/.local/dsh-node/lib/node_modules/pnpm/bin/pnpm.mjs \
       /root/.local/dsh-node/node24/bin/pnpm
```

No requiere reiniciar: es un archivo nuevo en disco, cualquier spawn
posterior ya lo encuentra.

**Nota de coordinación**: mientras `dsh.service` esté activo, usar
`systemctl {start,stop,restart} dsh.service` en vez de `dsh-manage.sh
{start,stop}` para no pisar el pidfile/gestión de puerto de ambos mecanismos
a la vez. Migrar `dsh-manage.sh` para que delegue a systemd cuando está
disponible queda pendiente (fuera de scope de esta etapa — cambia el
script).

## Protocolo de instalación

### Método preferido: Market UI (hot-mount, sin reiniciar en la mayoría de los casos)

`dsh-market` (ya instalado, sidebar → Market) sabe instalar plugins **sin
reiniciar el proceso** cuando el `cordis.patch.yml` del plugin es "simple"
(solo filas `insert:` con `id`+`name`). Internamente (`lib/hot.js`):

1. Instala con pnpm igual que por CLI.
2. Intenta montar el plugin en el proceso vivo (`hotMount`).
3. Si lo logra → queda activo al toque, sin bajar el servicio.
4. Si el patch tiene config/expresiones que no puede montar en caliente →
   la UI dice explícitamente **"requiere reinicio"**, en vez de fallar en
   silencio.
5. Después de instalar valida que el paquete no rompa el árbol (manifest
   presente, entry cargable, sin conflicto de `id` con otro plugin) y lo
   revierte solo si hace falta — la lógica que ya auditamos en `install.ts`.

**Flujo recomendado**: entrar a `http://127.0.0.1:3080` → Market → buscar
el plugin por el nombre npm de la tabla de abajo → instalar. Si dice
"activo, sin reinicio", listo. Si dice "requiere reinicio", recién ahí un
`dsh-manage stop && dsh-manage start` — sabiendo de antemano que hace falta,
no a ciegas.

### Método CLI (fallback, cuando no se puede usar la GUI)

```bash
export PATH="/root/.local/dsh-node/bin:/root/.local/dsh-node/node24/bin:$PATH"
cd /root/.dsh/profiles/web

# 1. Instalar UN plugin
dsh plugin --profile web add <paquete-npm-exacto>

# 2. Aprobar builds nativos si pnpm los bloquea (verificar que sean esperados)
pnpm approve-builds

# 3. Reinicio limpio (verificar puerto libre antes de start) — el CLI
#    siempre requiere este paso; no tiene hot-mount, a diferencia del Market.
/root/dsh-test/dsh-manage.sh stop
sleep 3
ss -ltnp | grep ':3080 ' && echo "OJO: algo sigue escuchando" || echo "puerto libre"
timeout 60 /root/dsh-test/dsh-manage.sh start

# 4. Verificar boot real (no solo que el comando no diera error)
grep -iE 'duplicate|failed to load|cannot find package|EADDRINUSE' /root/dsh-test/dsh.log | tail -20
curl -sS -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://127.0.0.1:3080/

# 5a. Si OK: actualizar este archivo a ✅, seguir con el próximo.
# 5b. Si FALLA: revertir YA
dsh plugin --profile web remove <paquete-npm-exacto>
/root/dsh-test/dsh-manage.sh stop && sleep 3 && /root/dsh-test/dsh-manage.sh start
# confirmar que vuelve a levantar, documentar el motivo del fallo acá, seguir con el próximo
```

## Cola de instalación pendiente (usar el nombre npm exacto en el Market)

Los siguientes están seleccionados y con nombre npm ya verificado — pendiente
instalar uno por uno desde la GUI del Market:

```
dsh-plugin-verify        (ya activo, no reinstalar — ver hotfix arriba)
@perrylink/dsh-skill-pack-security-provider
dsh-defend
dsh-mask
dsh-secret-guard
dsh-plugin-gate
dsh-guardian
dsh-permission-rules
@akslcw/dsh-negative-ledger
dsh-taskboard
dsh-plugin-solo-thinking
dsh-github
aegis
@linxin666/dsh-ssh
@fakechris/dsh-restart-recover
dsh-update-checker
dsh-observe
dsh-fast
dsh-context
dsh-budget
dsh-startup-guard
dsh-plugin-clinic
dsh-test-drive
@dickpy/dsh-cloud-sync
```

`dsh-code-check` no está en npm — se instala solo por CLI con
`dsh plugin --profile web add "github:a179-sanae/dsh-code-check#main"`.
