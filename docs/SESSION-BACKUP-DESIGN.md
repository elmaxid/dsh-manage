# Diseño técnico — `dsh-manage session-backup`

Estado: propuesta de diseño (sin implementar).
Target: dsh-manage ≥ 1.2.0, DSH 0.1.1-rc.2.
Autor: arquitectura DSH.

---

## 0. Hechos verificados (base del diseño)

Todo lo que sigue fue confirmado leyendo el harness instalado en
`/root/.local/dsh-node/node24/lib/node_modules/@deepseek-ai/dsh/`, no inferido.

### 0.1 Layout en disco

```
$DSH_HOME/sessions/<workspace-slug>/<session-id>/session.jsonl.zstd
```

- `<workspace-slug>` es una derivación opaca del `cwd`
  (`/opt/vpn-monitor-mke` → `--opt-vpn-monitor-mke--`,
  `/root/.dsh/profiles/repro` → `--root-.dsh-profiles-repro--`).
  **Decisión: nunca re-derivar el slug.** Se enumeran directorios y se lee el
  `cwd` real del header. Re-implementar la función de slug es una fuente
  garantizada de divergencia en el próximo release.
- `<session-id>` a veces trae prefijo `session-` y a veces no (ambas formas
  coexisten hoy en el mismo host). El id autoritativo es el del header.
- El backend soporta `session.jsonl.zstd` **o** `session.jsonl` plano, según
  `compression`. `rejectOppositeArtifact()` garantiza que solo exista uno de
  los dos por sesión. El comando debe manejar ambos.

### 0.2 Formato del log

- zstd **multi-frame concatenado** (la sesión de vpn-monitor tiene 1957 frames
  para 4735 líneas). `zstd -dc` concatena frames transparentemente.
- Primera línea = header:
  ```json
  {"type":"session","version":0,"id":"session-67436620-…","createdAt":1787658011276,"cwd":"/opt/vpn-monitor-mke","delegationDepth":0,"agentPreset":"cordis"}
  ```
- Resto = eventos: `{"type":…,"seq":…,"time":…,"data":{…}}`, con campo
  opcional `ignorable`.

### 0.3 La causa raíz exacta del incidente

`dsh-session-persistence/lib/index.js:1119`:

```js
if (KNOWN_SESSION_EVENT_TYPES.has(event.type) || event.ignorable === true) continue;
throw this.unsupported(meta, `session "…" contains event type "…" unknown to this harness and not marked ignorable; …`);
```

- `KNOWN_SESSION_EVENT_TYPES` (en `@deepseek-ai/dsh-session/lib/index.js:1054`)
  es un `Set` **mutable en runtime**, con 48 tipos first-party (verificado por conteo en el host).
- `dsh-swarm-panel` hace `known.add(type)` para 14 tipos `swarm/*` **como
  efecto de su ciclo de vida** (`lib/index.js:2485`), y el disposer los
  borra. Su propio comentario lo dice: *"unloading the plugin removes the
  types again, after which a swarm session correctly reads as
  written-by-a-newer-harness"*. El fallo es **por diseño del plugin**, no un
  bug.
- **Confirmado en el log real**: los eventos `swarm/*` de
  `--opt-vpn-monitor-mke--/session-67436620-…` tienen `"ignorable": null`,
  **no** `true`. Por eso el escape hatch del envelope no los salva.
  (70 eventos `swarm/*` en esa sesión: `role-spawned`, `role-message`,
  `checkpoint`, `topology-changed`, `created`, `destroyed`, `context-updated`,
  `chat-started`, `role-exited`.)

Conclusión de diseño: **el riesgo es determinable estáticamente**. Un tipo de
evento es peligroso si no está en el catálogo first-party y no está marcado
`ignorable: true`. No hace falta adivinar.

### 0.4 Semántica de escritura (define las reglas de seguridad)

- Append normal: `open(path, "a")` + `writeFile` + `fsync`, con rollback por
  truncado al tamaño previo si el write falla (`appendLines`, línea 1200).
- Rematerialización: temp file + `link()` + fsync de directorio
  (`materializePosix`, línea 1108) — es decir, **cambia el inode**.
- Lectura: `readStableFile()` hace `stat` → `readFile` → `stat` y reintenta
  mientras la revisión cambie.

De acá salen dos reglas duras:

1. **Copiar un log vivo puede capturar una cola rota.** Se replica la
   estrategia de `readStableFile`: stat-antes / copiar / stat-después, y
   reintentar. DSH tolera colas rotas en lectura (`tornMarker`), así que una
   copia con cola rota sigue siendo restaurable — pero hay que marcarla.
2. **Restaurar con DSH corriendo es inseguro.** El writer tiene un fd abierto
   en modo append. Reemplazar el archivo por rename deja al writer escribiendo
   sobre el inode viejo (ya desenlazado): la restauración se pierde en
   silencio y el log diverge. `restore` **exige DSH detenido**.

---

## 1. Arquitectura del comando

Un comando nuevo en el dispatcher, con subcomandos propios:

```
dsh-manage session-backup <subcomando> [opciones]
```

| Subcomando | Qué hace | Escribe en `sessions/` |
|---|---|---|
| `scan` | Clasifica todas las sesiones por riesgo. Read-only. | no |
| `create` | Crea un snapshot con timestamp. | no |
| `list` | Lista snapshots y su contenido. | no |
| `verify` | Verifica integridad de un snapshot (checksums + `zstd -t` + header). | no |
| `restore` | Restaura una sesión (o todas) desde un snapshot. | **sí** |
| `repair` | Marca eventos huérfanos como `ignorable:true` in-place. | **sí** |
| `prune` | Borra snapshots viejos según retención. | no |

Solo `restore` y `repair` tocan `sessions/`, y ambos hacen backup previo
obligatorio (§5.2).

### 1.1 Flags

**Globales**

| Flag | Default | Descripción |
|---|---|---|
| `--profile <n>` | `web` | Profile de donde sale el vocabulario de plugins. |
| `--backup-root <dir>` | `$DSH_HOME/session-backups` | Raíz de snapshots. |
| `--json` | off | Salida JSON en vez de texto (para CI / hooks). |
| `--quiet` | off | Solo errores. |
| `--dry-run` | off | Muestra el plan, no escribe nada. |

**`scan`**

| Flag | Descripción |
|---|---|
| `--workspace <slug>` | Limitar a un workspace. |
| `--session <id>` | Limitar a una sesión. |
| `--risk <ok\|at-risk\|broken>` | Filtrar por clase de riesgo. |
| `--owner <pkg>` | Solo sesiones con eventos de ese paquete. |
| `--fail-on-risk` | Sale ≠0 si hay sesiones `at-risk` o `broken`. |

**`create`**

| Flag | Descripción |
|---|---|
| `--label <txt>` | Sufijo del nombre del snapshot (`preremove-dsh-swarm-panel`). |
| `--reason <txt>` | Texto libre al manifest. |
| `--only-at-risk` | Solo sesiones no-OK (el caso normal antes de tocar plugins). |
| `--workspace` / `--session` | Selección puntual. |
| `--include-live` | Incluye sesiones con escritor activo (marca `partial`). Sin esto se saltean y se avisa. |
| `--no-dedup` | Desactiva el hardlink contra el snapshot anterior. |

**`restore`**

| Flag | Descripción |
|---|---|
| `--from <snapshot\|latest>` | Snapshot origen (obligatorio). |
| `--session <id>` | Restaurar una sola (default: todas las del snapshot). |
| `--force` | Pisar un log existente que difiere del backup. |
| `--to-new-id` | Restaurar como sesión nueva sin tocar la original. |

**`repair`**

| Flag | Descripción |
|---|---|
| `--session <id>` | Obligatorio: nunca opera en lote por default. |
| `--mark-ignorable` | Único modo hoy (explícito, no default). |
| `--types <a,b>` | Restringir a ciertos tipos. |
| `--yes` | Confirmación no interactiva. |

**`prune`**

| Flag | Default | Descripción |
|---|---|---|
| `--keep <n>` | 10 | Snapshots a conservar. |
| `--older-than <días>` | — | Alternativa por edad. |
| `--yes` | — | Requerido para borrar de verdad. |

---

## 2. Estructura de directorios de backup

Raíz por default `$DSH_HOME/session-backups/` — **hermana** de `sessions/`,
nunca hija. Es deliberado: cualquier cosa bajo `sessions/` es candidata a que
el backend la enumere. Además sigue la convención que el repo ya tiene en ese
nivel (`repair-backups/`, `plugin-snapshots/`).

```
$DSH_HOME/session-backups/
├── latest -> 20260825T143012Z-preremove-dsh-swarm-panel
├── 20260825T143012Z-preremove-dsh-swarm-panel/
│   ├── MANIFEST.json
│   ├── CHECKSUMS.sha256
│   ├── vocabulary.json
│   ├── scan.json
│   └── sessions/
│       └── --opt-vpn-monitor-mke--/
│           └── session-67436620-4931-423a-aeac-3b7eb7b03ec9/
│               └── session.jsonl.zstd
└── 20260824T090001Z-manual/
    └── …
```

- Nombre: `<UTC ISO básico>-<label>`. UTC siempre (colegas en husos distintos,
  y ordena lexicográficamente = cronológicamente).
- El árbol bajo `sessions/` **replica exactamente** el layout original. Eso
  hace que `restore` sea una copia posicional trivial y auditable, y que un
  humano pueda recuperar a mano con `cp` si el script no está.
- `latest` es symlink relativo, actualizado atómicamente
  (`ln -sfn` a un temp + `mv -T`).
- **Escritura atómica del snapshot**: se construye en `<nombre>.partial/` y se
  renombra al nombre final recién al terminar. Un directorio con nombre final
  es, por invariante, un snapshot completo. `verify` y `restore` ignoran
  `*.partial`.

### 2.1 `MANIFEST.json`

```json
{
  "schemaVersion": 1,
  "createdAt": "2026-08-25T14:30:12Z",
  "label": "preremove-dsh-swarm-panel",
  "reason": "antes de dsh plugin remove dsh-swarm-panel",
  "trigger": "plugins-remove",
  "host": "dev-01",
  "dshManageVersion": "1.2.0",
  "dshVersion": "0.1.1-rc.2",
  "sessionFormatVersion": 0,
  "dshHome": "/root/.dsh",
  "profile": "web",
  "sessions": [
    {
      "id": "session-67436620-4931-423a-aeac-3b7eb7b03ec9",
      "workspace": "--opt-vpn-monitor-mke--",
      "cwd": "/opt/vpn-monitor-mke",
      "createdAt": 1787658011276,
      "agentPreset": "cordis",
      "headerVersion": 0,
      "artifact": "session.jsonl.zstd",
      "compression": "zstd",
      "bytes": 1367799,
      "sha256": "…",
      "events": 4735,
      "risk": "at-risk",
      "partial": false,
      "unknownTypes": [
        { "type": "swarm/role-spawned", "count": 22, "owner": "dsh-swarm-panel@0.1.0" },
        { "type": "swarm/role-message", "count": 17, "owner": "dsh-swarm-panel@0.1.0" }
      ]
    }
  ]
}
```

`CHECKSUMS.sha256` en formato `sha256sum` estándar, con rutas relativas al
directorio del snapshot → `sha256sum -c` funciona sin el script.

`vocabulary.json` congela el catálogo usado en ese momento: los 48 tipos
first-party + el mapa `tipo → paquete@versión`. Es lo que permite, meses
después, saber **qué plugin exacto hay que reinstalar** para leer el backup.
Esto es la diferencia entre "tengo los bytes" y "puedo recuperar la sesión".

---

## 3. Detección de eventos de tipos desconocidos

Tres insumos, en orden de autoridad.

### 3.1 Catálogo first-party (baseline)

Se extrae del harness instalado, **no** se hardcodea:

```
$DSH_NODE/../lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js
```

Se parsea el literal `const KNOWN_SESSION_EVENT_TYPES = new Set([ … ])` (hoy
48 entradas, desde `agent-preset/selected` hasta
`web/deepseek-search-llm-request`).

**Regla de seguridad crítica**: si el parseo devuelve menos de N entradas
(N=20 como piso de cordura), es un fallo duro — se aborta con mensaje claro.
Un baseline vacío marcaría *toda* sesión como `broken` y podría inducir un
`repair` masivo destructivo. Se acompaña con un snapshot vendorizado en
`plugins/known-session-event-types.json` como **fuente de comparación**
(avisa si el harness cambió el catálogo), nunca como reemplazo silencioso.

### 3.2 Vocabulario declarado por plugins

Se escanea `$DSH_HOME/profiles/<profile>/node_modules/*/lib/*.js` buscando el
patrón de registro (`KNOWN_SESSION_EVENT_TYPES` + los literales que se
agregan). Hoy en el profile `web` da exactamente un hit: `dsh-swarm-panel`,
con sus 14 tipos `swarm/*` — incluidos 5 que todavía no aparecen en ningún log
(`swarm/resumed`, `swarm/hitl-requested`, `swarm/hitl-resolved`,
`swarm/chat-ended`, `swarm/memory-written`).

Esto produce el mapa `tipo → paquete@versión`, que es lo que convierte
"esta sesión está rota" en "reinstalá `dsh-swarm-panel@0.1.0`".

**Hallazgo importante**: `dsh-swarm-panel@0.1.0` está instalado en los
profiles `web` y `repro`, pero **no figura** en `plugins/manifest.json` — ni en
`dependencies` ni en `bundles`. El único event-writer conocido del host está
*fuera* del stack homologado, instalado a mano. Dos consecuencias:

- El gate no puede depender solo del manifest: el escaneo del `node_modules`
  real es obligatorio, porque es el único lugar donde este plugin aparece.
- `plugins-install` es merge-only y no remueve lo que no está en el manifest,
  así que hoy no lo borra. Pero cualquier operación futura que reconcilie el
  profile contra el manifest lo desinstalaría y reproduciría el incidente
  exacto. Vale decidir aparte si `dsh-swarm-panel` se homologa (entra al
  manifest) o se documenta explícitamente como out-of-band.

Fallback: si el patrón no matchea (plugin minificado, otra forma de registro),
se cae a heurística de prefijo — el segmento antes de `/` del tipo desconocido
se busca como substring en los nombres de paquete instalados. Se reporta como
`owner: "dsh-swarm-panel (inferido)"`, nunca como certeza.

### 3.3 Escaneo de los logs

Por sesión:

```
zstd -dc session.jsonl.zstd | jq -c 'select(.ignorable != true) | .type'
```

…agrupado y contado. Se descarta la primera línea (header, `type:"session"`,
que no es un evento). Se respeta `ignorable === true` con la misma semántica
estricta del harness: `null` **no** cuenta (es exactamente lo que hundió a
vpn-monitor).

Para logs grandes se corta con `head -c` solo en modo `--quick`; el default
lee entero (1.3 MB comprimidos tardan ~200 ms, no vale la pena optimizar).

### 3.4 Clasificación

| Clase | Condición | Significado |
|---|---|---|
| `ok` | Todos los tipos en el baseline. | Inmune a install/remove de plugins. |
| `at-risk` | Hay tipos fuera del baseline, pero un plugin **instalado** los declara. | Carga hoy; **se rompe si se desinstala ese plugin**. |
| `broken` | Hay tipos fuera del baseline y ningún plugin instalado los declara. | Ya no carga. Es el estado en que quedó vpn-monitor. |
| `unsupported-version` | `header.version != 0`. | Escrita por otro formato; fuera de alcance, solo backup. |
| `unreadable` | zstd o header no parsean. | Corrupción física; backup y flag, sin tocar. |

`scan` sale con código 0 si todo `ok`; con `--fail-on-risk`, código 3 si hay
`at-risk` y 4 si hay `broken`. Eso lo hace usable como gate en CI o en un
`ExecStartPre`.

Salida típica:

```
workspace                     sesión              eventos  riesgo    dueño
--opt-vpn-monitor-mke--       session-67436620…      4735  at-risk   dsh-swarm-panel@0.1.0 (70 ev. swarm/*)
--opt-deudores-mke--          session-6dd887f9…       412  ok        —
--opt-tmanager--              session-ca9970e1…       880  ok        —

3 sesiones at-risk en 1 workspace. 1 plugin las sostiene: dsh-swarm-panel.
   → dsh-manage session-backup create --only-at-risk --label pre-cambios
```

---

## 4. Integración con `plugins-install` / `plugins-remove`

### 4.1 Concepto: "plugin que escribe eventos de sesión"

Un paquete es *event-writer* si su código registra tipos (§3.2). Se evalúa
**contra el tarball/dir del paquete**, así que se puede saber antes de
instalar y antes de remover.

### 4.2 Gate compartido

Una función interna `session_backup_guard <acción> <paquetes…>` que:

1. Corre `scan`.
2. Calcula el **delta de vocabulario** que produce la acción.
3. Decide backup / aviso / bloqueo.
4. Devuelve un código que el llamador respeta.

Se invoca desde `plugins_install()` (antes del `pnpm install`, después de
validar el manifest) y desde un `plugins_remove()` nuevo.

### 4.3 `plugins-remove` (dirección crítica)

Es la dirección que causó el incidente. Flujo:

1. Determinar los tipos que el paquete a remover declara.
2. Buscar sesiones que **contengan** esos tipos → esas pasan de `at-risk` a
   `broken` al remover.
3. Si hay ≥1:
   - `create --only-at-risk --label preremove-<pkg> --trigger plugins-remove`
     (automático, **no** opcional).
   - Mostrar el impacto explícito:
     ```
     ⚠ remover dsh-swarm-panel va a dejar ilegibles 3 sesiones:
         --opt-vpn-monitor-mke--/session-67436620…  (70 eventos swarm/*)
       backup creado: $DSH_HOME/session-backups/20260825T143012Z-preremove-dsh-swarm-panel
       opciones:
         a) reinstalar el plugin para volver a leerlas
         b) dsh-manage session-backup repair --session … --mark-ignorable
            (las sesiones cargan, los eventos swarm/* se omiten)
     ```
   - Exigir confirmación: interactivo por default, `--yes` en no-interactivo.
     **Sin `--yes` y sin TTY, aborta.** Nunca romper sesiones en silencio.
4. Recién ahí `pnpm remove` en el profile dir + restart (reusando el bloque de
   restart/`wait_for_port` que `plugins_install` ya tiene — se extrae a
   `restart_dsh()` y lo comparten).

### 4.4 `plugins-install`

Riesgo menor pero no nulo: una **actualización** de un event-writer puede
renombrar o quitar tipos, y ahí un log viejo queda huérfano igual.

- Si algún paquete del manifest es event-writer → `create --only-at-risk`
  automático antes de tocar nada. Es barato (§4.6) y compra la reversión.
- Si un upgrade **reduce** el vocabulario declarado (tipos presentes en la
  versión instalada que la nueva ya no declara), avisar con el mismo formato
  que 4.3, listando las sesiones afectadas.
- Post-install: correr `scan` y reportar el delta. Si aparecen `broken` que
  antes no estaban, se avisa fuerte y se menciona el snapshot recién creado.
  Encaja con el bloque de verificación de log que `plugins_install` ya hace
  después de `wait_for_port`.

### 4.5 Punto de integración con el manifest

`plugins/manifest.json` gana una clave opcional:

```json
"sessionEventWriters": {
  "dsh-swarm-panel": { "prefixes": ["swarm/"], "note": "registra su vocabulario como efecto; al descargarlo las sesiones con swarm/* dejan de cargar" }
}
```

Es **caché declarativa y documentación**, no la fuente de verdad — la fuente
sigue siendo el escaneo de §3.2. Sirve para (a) avisar antes de que el paquete
esté instalado, y (b) dejar escrito el incidente donde el próximo colega lo va
a leer.

### 4.6 Costo

Con dedup por hardlink contra el snapshot anterior (`cp -l` cuando el sha256
coincide), un `create` repetido sin cambios cuesta bytes de inode. El corpus
actual (26 MB en 8 workspaces) hace que hasta el peor caso sea irrelevante en
un server de desarrollo.

---

## 5. Manejo de errores y seguridad

### 5.1 Invariantes duros

1. **`scan`, `create`, `list`, `verify` y `prune` nunca escriben bajo
   `$DSH_HOME/sessions/`.** Ni un `.bak`, ni un temp. (Nota: hoy ya hay un
   `session.jsonl.zstd.bak` suelto en `--opt-deudores-mke--` dejado por otra
   herramienta; este comando no agrega a ese patrón.)
2. **Copiar, nunca mover.** El original se abre solo en lectura.
3. **Todo snapshot se verifica antes de publicarse**: `zstd -t` sobre cada
   artefacto + header parseable + sha256 registrado. Si algo falla, el
   directorio queda como `.partial` y el comando sale ≠0.
4. **`restore` y `repair` hacen `create` implícito** del estado actual antes de
   escribir (label `pre-restore` / `pre-repair`). Un rollback siempre existe.
5. **`restore` y `repair` exigen DSH detenido.** Chequeo vía `port_pid()`, que
   el script ya tiene. Motivo en §0.4 regla 2: no es prudencia, es que el fd en
   append del writer hace que la restauración se pierda. Sin override.
6. **Toda operación destructiva pasa por `gate_guard`** antes de ejecutarse
   (`prune`, y el reemplazo de archivos en `restore`).

### 5.2 Lectura estable de logs vivos

Se replica `readStableFile`:

```
stat (size, mtime_ns, inode) → copiar → stat de nuevo
  iguales → OK
  distintos → reintentar (hasta 3)
  3 fallos → si --include-live: aceptar y marcar "partial": true
             si no: saltear y avisar
```

Un log con cola rota **sigue siendo restaurable**: el coordinator de DSH
descarta el fragmento torn y cierra el turno con eventos sintéticos. Se
documenta en la salida para que nadie crea que el backup está corrupto.

### 5.3 Concurrencia

Lock por `flock` sobre `$DSH_HOME/session-backups/.lock` para todo subcomando
que escriba. Dos colegas corriendo `create` en paralelo no se pisan; el
segundo espera o sale con aviso (`flock -w 30`).

### 5.4 Permisos

`sessions/` es `0700` y los logs `0600`. El backup replica: directorios `0700`,
archivos `0600`, con `umask 077` al inicio del comando. Los logs contienen
prompts completos, rutas y potencialmente secretos — un backup `0644` sería
una regresión de seguridad silenciosa en un server compartido.

### 5.5 `repair --mark-ignorable`

El escape hatch sancionado por el propio contrato del envelope: agregar
`"ignorable": true` a los eventos huérfanos hace que
`assertEventsSupported()` los saltee y la sesión cargue **sin el plugin**.
Costo: esos eventos dejan de interpretarse (la sesión carga, el panel de swarm
no muestra nada).

Reglas:

- `--session` obligatorio; nunca en lote.
- Solo toca líneas cuyo `type` está fuera del baseline. Las demás se copian
  **byte a byte** — no se re-serializa JSON de eventos conocidos (round-trip
  por `jq` puede alterar orden de claves o números; no vale el riesgo).
- `seq` y `time` intactos: solo se agrega un campo.
- Reescritura sobre temp + verificación (`zstd -t`, recuento de líneas igual,
  header idéntico) + `mv` atómico. Frame único es válido: el decoder concatena
  frames, no depende de sus límites.
- Backup previo obligatorio, DSH detenido.

**Gate de validación previo a shipear** (no dar por hecho que funciona): tomar
una copia de `--opt-vpn-monitor-mke--/session-67436620-…`, marcar sus 70
eventos `swarm/*`, desinstalar `dsh-swarm-panel` en un profile de prueba
(`repro`, ya existe) y confirmar que la sesión carga. Si `adoptSessionEvent`
rechaza un `ignorable` desconocido en la normalización previa, este subcomando
no se implementa y `restore` + reinstalar el plugin queda como único camino.

### 5.6 Códigos de salida

| Código | Significado |
|---|---|
| 0 | OK. |
| 1 | Error de uso o fallo duro (sin `$DSH_HOME`, baseline no parseable, lock). |
| 2 | Nada que hacer (sin sesiones que matcheen). |
| 3 | `scan --fail-on-risk`: hay `at-risk`. |
| 4 | `scan --fail-on-risk`: hay `broken`. |
| 5 | Éxito parcial: el snapshot se creó pero N sesiones se saltearon. |

Con `set -euo pipefail`, cada subcomando encapsula sus fallos y devuelve el
código; nada de `|| true` global tapando errores.

---

## 6. Compatibilidad con DSH 0.1.1-rc.2

| Aspecto | Estado | Mitigación |
|---|---|---|
| `SESSION_FORMAT_VERSION = 0` | Verificado en el header de logs reales. | Se registra en el manifest. Header con `version != 0` → clase `unsupported-version`, solo backup. |
| zstd multi-frame | Verificado (1957 frames). `zstd -dc` lo maneja. | Requerir `zstd` ≥ 1.4 en preflight. |
| `session.jsonl` plano | Soportado por el backend según `compression`. | Detectar por nombre de archivo, no asumir `.zstd`. |
| Parseo de `KNOWN_SESSION_EVENT_TYPES` | Hoy es un literal legible en el bundle. | Un bundler futuro puede minificarlo → piso de cordura (§3.1) + snapshot vendorizado + aviso explícito. Nunca degradar en silencio. |
| Contrato `ignorable === true` | Verificado en el código. | Comparación estricta; `null`/`"true"` no cuentan. |
| Prefijo `session-` inconsistente en ids | Ambas formas conviven hoy. | El id sale del header; el directorio se trata como opaco. |
| Slug de workspace | Derivación no documentada. | Nunca re-derivar: enumerar y leer `cwd` del header. |
| `dsh plugin` = wrapper de pnpm | Confirmado en `dsh --help`. | `plugins_remove` usa `pnpm remove` en el profile dir, igual que `plugins_install` usa `pnpm install`. |
| Upgrade de DSH cambia el catálogo | Probable entre releases. | `create` congela `vocabulary.json`; `verify` avisa si el catálogo actual difiere del snapshot. |

**Dependencias**: `zstd`, `jq`, `sha256sum`, `flock`, `find`, `stat` — todas
presentes y verificadas en el host. Se agregan a un chequeo de preflight que
falla temprano con mensaje claro.

---

## 7. Plan de implementación

| Fase | Contenido | Valor |
|---|---|---|
| 1 | `scan` + extracción de baseline + mapa de vocabulario. Read-only. | Ya responde "¿qué sesiones están en riesgo hoy?" sin riesgo de romper nada. |
| 2 | `create` + `list` + `verify` + `MANIFEST.json`/`CHECKSUMS`. | Backup restaurable a mano con `cp`. |
| 3 | `restore` + `prune` + `gate_guard`. | Ciclo completo. |
| 4 | `session_backup_guard` + `plugins_remove` + hook en `plugins_install`. | Cierra el agujero que causó el incidente. |
| 5 | `repair --mark-ignorable`, **solo si pasa el gate de §5.5**. | Recuperación sin reinstalar el plugin. |

Fase 1 sola ya habría evitado el incidente: `plugins-remove` habría dicho
"esto rompe 3 sesiones" antes de tocar nada.

### 7.1 Tests (bats, siguiendo `tests/dsh-manage.bats`)

El patrón existente (`DSH_HOME` a un tmpdir, `--lib` para sourcear funciones)
sirve tal cual. Fixtures: generar logs JSONL sintéticos y comprimirlos con
`zstd` en `setup()` — nada de copiar sesiones reales al repo (contienen
prompts y rutas del host).

Casos mínimos:

- Sesión con solo tipos del baseline → `ok`.
- Sesión con `foo/bar` sin dueño → `broken`.
- Sesión con `foo/bar` + plugin fake que lo declara → `at-risk`.
- Sesión con `foo/bar` + `"ignorable": true` → `ok` (el caso que distingue
  este diseño del bug real).
- `"ignorable": null` → **no** cuenta como ignorable (regresión de vpn-monitor).
- `create` produce `MANIFEST.json` válido y `sha256sum -c` pasa.
- `create` interrumpido deja `.partial` y `list` no lo muestra.
- `restore` con DSH "corriendo" (puerto fake ocupado) → aborta.
- `prune --keep 2` conserva 2 y no borra el único backup de una `broken`.
- Baseline con <20 tipos → fallo duro, no marca todo como `broken`.

---

## 7.2 Enmienda: caché de proyección (`session_projcache.json`)

Gap detectado en revisión, **no** cubierto por el diseño original. Verificado
en el host:

- Ruta: `$DSH_HOME/storages/session_projcache.json` (23 MB hoy).
- Estructura: `{"unit":{"name":"session_projcache","version":3},"global":null,
  "tables":{"sessions":{ "<session-id>": {"identity":{...},"rows":{...}} }}}`.
- Contiene **50 sesiones**, incluida la rota
  (`session-67436620-4931-423a-aeac-3b7eb7b03ec9`).

Es caché **derivada** del log: si `restore` devuelve una sesión a un estado
anterior, o `repair` le cambia los eventos, la entrada cacheada queda
describiendo un log que ya no existe → estado inconsistente.

**Regla (obligatoria para Fase 3 y Fase 5)**: `restore` y `repair` deben
invalidar la entrada de cada sesión que tocan:

1. Backup del archivo completo antes de modificarlo (va dentro del snapshot,
   como `storages/session_projcache.json`).
2. Borrar **solo** la clave `tables.sessions["<session-id>"]` de las sesiones
   afectadas — no truncar el archivo entero (las otras 49 sesiones son válidas
   y regenerarlas es caro).
3. Reescritura atómica: temp + `mv`, con `umask 077`.
4. Requiere DSH detenido, igual que `restore`/`repair` (misma razón del §0.4:
   el proceso vivo tiene su propia vista en memoria).

Si la clave no existe, es no-op silencioso (la caché se repuebla sola).

**Fuera de alcance de Fase 1+2**: esas fases son read-only sobre `sessions/`
y no modifican logs, así que no pueden dejar la caché inconsistente. La
implementación de esta enmienda pertenece al plan que construya `restore`.

---

## 8. Riesgos residuales

1. **`repair` es lossy.** Los eventos marcados dejan de interpretarse. La
   salida debe decirlo cada vez, sin eufemismos.
2. **El escaneo de vocabulario es heurístico** para plugins que registren de
   otra forma. Mitigado con el fallback por prefijo, siempre marcado como
   inferido.
3. **Backup ≠ inmunidad.** Restaurar una sesión `broken` sin reinstalar el
   plugin la deja igual de ilegible. Por eso `vocabulary.json` es parte del
   snapshot: es la receta de qué reinstalar.
4. **Un upgrade de DSH que quite tipos del baseline** convierte sesiones `ok`
   en `broken` sin que nadie toque un plugin. Se cubre corriendo `scan` después
   de `update`, y es un buen candidato a agregarlo ahí en una fase posterior.
