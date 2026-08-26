# Session Backup (Fases 3-5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Completar `dsh-manage session-backup` con `restore`, `prune` y `repair`, y cerrar la causa raíz del incidente original integrando un gate de resguardo en `plugins-install`/`plugins-remove` (nuevo).

**Architecture:** Extiende el `dsh-manage.sh` y `plugins/session-scan.py` que ya existen (Fase 1+2, mergeada como v1.2.0). `restore`/`repair` son las primeras funciones de todo el feature que escriben bajo `$DSH_HOME/sessions/` — por eso cada una hace un `create` implícito antes de tocar nada, exige DSH detenido, y usa escritura atómica (`cp` a temp + `mv -T`). `plugins_remove()` es nueva; reusa el patrón de restart que `plugins_install()` ya tiene, extraído a una función compartida.

**Tech Stack:** bash (`set -euo pipefail`), python3 + zstd/sha256sum/flock, bats-core.

**Spec:** `docs/SESSION-BACKUP-DESIGN.md` (§1, §4, §5, §7 completo — fases 3, 4 y 5; más las enmiendas §7.2, §7.3, §7.4)

---

## Contexto: qué cambió desde el spec original (leer antes de implementar)

1. **El gate de `repair --mark-ignorable` (§5.5) ya se ejecutó y pasó** (§7.3 del spec, verificado contra el harness real: 34789 eventos, 0 rechazados, round-trip lossless). `repair` entra a este plan con confianza, no como "TBD".
2. **`readStableFile` real del harness** (`dsh-session-persistence-jsonl/lib/index.js:904`) compara `(dev, ino, size, mtimeNs, ctimeNs)` en un loop **sin timeout** — el spec decía "hasta 3 reintentos" de forma aproximada. Este plan implementa su propia versión con **timeout acotado** (a diferencia del harness, un comando de operador no puede bloquearse indefinidamente); se documenta la diferencia en el código.
3. **`plugins_remove()` no existe hoy** en `dsh-manage.sh` — es 100% nueva. Reusa `port_pid()`/`wait_for_port()` que ya existen (líneas 92/104).
4. **`dsh plugin` es un wrapper directo a pnpm** en el profile dir (confirmado: `dsh plugin --profile <p> remove <pkg>` == `cd profile_dir && pnpm remove <pkg>`). Este plan usa `pnpm remove` directo en `plugins_remove()`, igual que `plugins_install()` ya usa `pnpm install`.
5. **`gate_guard` del spec (§5.1 regla 6) es conceptual** — no existe como función de este proyecto ni hay que invocar nada externo; significa "antes de una operación destructiva, confirmar el target exacto", que este plan implementa con los checks explícitos de cada subcomando (no hay una tool `gate_guard` que el script deba llamar).

---

## Global Constraints

- Bash con `set -euo pipefail`; shellcheck limpio (`make check`).
- Comentarios y salida al usuario en español.
- **`restore` y `repair` son las únicas funciones que escriben bajo `$DSH_HOME/sessions/`.** Todo lo demás (`scan`, `create`, `list`, `verify`, `prune`) sigue siendo read-only ahí.
- **`restore` y `repair` exigen DSH detenido** (spec §5.1 regla 5, §0.4 regla 2): sin excepción, sin override. Motivo verificado: el writer mantiene un fd en modo append; reemplazar el archivo por debajo pierde la escritura en silencio.
- **`restore` y `repair` hacen `create` implícito** del estado actual antes de escribir (label `pre-restore-<timestamp>` / `pre-repair-<session>-<timestamp>`). Rollback siempre disponible.
- **Escritura atómica**: `cp` a `<destino>.tmp` en el mismo directorio + `mv -T` al nombre final. Nunca escribir directo sobre el archivo que se está reemplazando.
- **`repair` copia byte a byte lo que no toca** — nunca re-serializa JSON de líneas que no son el tipo a marcar (verificado en la práctica: re-serializar TODO cambia 6732 líneas sin motivo semántico).
- Nombres de función y contrato JSON existentes (no romper): `dsh_session_lib_path()`, `session_backup_preflight()`, `DSH_BACKUP_ROOT`, `session_backup_verify_dir()`, contrato `sessions[].{workspace,directory,artifact,id,cwd,createdAt,events,risk,torn,unknownTypes}` de `MANIFEST.json`.
- `DSH_MANAGE_VERSION` actual: `1.2.0` (línea 42 de `dsh-manage.sh`). Este plan la sube a `1.3.0` en la última tarea.
- Interfaz declarada por el spec §1.1 para los subcomandos nuevos, implementada en las tareas correspondientes: `restore` (`--from`, `--session`, `--force`, `--to-new-id`), `repair` (`--session` obligatorio, `--mark-ignorable`, `--types`, `--yes`), `prune` (`--keep`, `--older-than`, `--yes`).

---

## File Structure

| Archivo | Responsabilidad |
|---|---|
| `plugins/session-scan.py` (modificar) | Nuevas funciones puras: `read_stable_bytes()`, `repair_events()`. |
| `dsh-manage.sh` (modificar) | `session_backup_restore()`, `session_backup_prune()`, `session_backup_repair()`, `session_backup_guard()` (gate compartido), `plugins_remove()` (nueva), hook en `plugins_install()`, `restart_dsh()` (extraída de `plugins_install`), `invalidate_projcache_entry()`. |
| `plugins/manifest.json` (sin cambios de contenido — ya tiene `sessionEventWriters`) | Fuente de la lista de event-writers conocidos para el gate (además del escaneo dinámico). |
| `tests/session-backup.bats` (modificar) | Tests de las 8 tareas. |
| `README.md`, `CHANGELOG.md`, `dsh-manage.sh` (modificar) | Documentación y bump a 1.3.0. |

---

### Task 1: `restore`

**Files:**
- Modify: `plugins/session-scan.py`
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_preflight()`, `dsh_session_lib_path()`, `DSH_BACKUP_ROOT`, `session_backup_verify_dir()`, `session_backup_create()` (Fase 1+2, ya en `main`).
- Produces: `port_pid_check()` (bash, wrapper de `port_pid()` existente que da mensaje claro), `session_backup_restore()` (bash), CLI `session-scan.py restore-plan --snap-dir <dir> --sessions <dir> [--session <id>]` → JSON con el plan de restauración (qué copiar, a dónde), sin ejecutar nada (el bash hace la copia real).

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "restore exige DSH detenido" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r1--" "session-r1" "session-r1" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r1
  # DSH_PORT apuntando a un puerto donde SI hay algo escuchando (el propio bats
  # no escucha nada, asi que forzamos con nc en background para simular "corriendo")
  DSH_PORT=39217
  ( exec 3<>/dev/tcp/127.0.0.1/1 ) 2>/dev/null || true  # no-op si /dev/tcp no disponible
  python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 39217))
s.listen(1)
import os
if os.fork() == 0:
    s.accept()
else:
    import time; time.sleep(0.3)
" &
  sleep 0.2
  run env DSH_PORT=39217 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest
  kill %1 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"corriendo"* ]] || [[ "$output" == *"detene"* ]]
}

@test "restore sin DSH corriendo restaura una sesion desde el snapshot" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r2--" "session-r2" "session-r2" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r2
  # simulamos que la sesion se corrompio despues del backup
  printf 'CORRUPTO' > "$DSH_HOME/sessions/--ws-r2--/session-r2/session.jsonl.zstd"
  run env DSH_PORT=39218 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest
  [ "$status" -eq 0 ]
  # el archivo restaurado debe volver a ser el zstd valido, no la basura
  run zstd -t "$DSH_HOME/sessions/--ws-r2--/session-r2/session.jsonl.zstd"
  [ "$status" -eq 0 ]
}

@test "restore --session limita a una sola sesion" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r3--" "session-r3a" "session-r3a" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  fake_session "$DSH_HOME/sessions" "--ws-r3--" "session-r3b" "session-r3b" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r3
  printf 'CORRUPTO-A' > "$DSH_HOME/sessions/--ws-r3--/session-r3a/session.jsonl.zstd"
  printf 'CORRUPTO-B' > "$DSH_HOME/sessions/--ws-r3--/session-r3b/session.jsonl.zstd"
  run env DSH_PORT=39219 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --session session-r3a
  [ "$status" -eq 0 ]
  run zstd -t "$DSH_HOME/sessions/--ws-r3--/session-r3a/session.jsonl.zstd"
  [ "$status" -eq 0 ]
  # r3b NO se toco, sigue corrupto
  [ "$(cat "$DSH_HOME/sessions/--ws-r3--/session-r3b/session.jsonl.zstd")" = "CORRUPTO-B" ]
}

@test "restore --to-new-id no pisa la sesion original" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r4--" "session-r4" "session-r4" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r4
  original_content="$(cat "$DSH_HOME/sessions/--ws-r4--/session-r4/session.jsonl.zstd")"
  run env DSH_PORT=39220 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --session session-r4 --to-new-id
  [ "$status" -eq 0 ]
  # la original sigue intacta
  [ "$(cat "$DSH_HOME/sessions/--ws-r4--/session-r4/session.jsonl.zstd")" = "$original_content" ]
  # y aparecio un directorio nuevo bajo el mismo workspace
  count="$(find "$DSH_HOME/sessions/--ws-r4--" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [ "$count" -eq 2 ]
}

@test "restore hace backup implicito antes de escribir" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r5--" "session-r5" "session-r5" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r5
  before_count="$(find "$DSH_BACKUP_ROOT" -maxdepth 1 -type d ! -name '*.partial' | wc -l)"
  run env DSH_PORT=39221 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest
  [ "$status" -eq 0 ]
  after_count="$(find "$DSH_BACKUP_ROOT" -maxdepth 1 -type d ! -name '*.partial' | wc -l)"
  # debe haber al menos un snapshot nuevo (el pre-restore automatico)
  [ "$after_count" -gt "$before_count" ]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `restore` no es un subcomando válido.

- [ ] **Step 3: Agregar `restore-plan` al helper Python**

Agregar a `plugins/session-scan.py`, antes de `main()`:

```python
def cmd_restore_plan(args):
    """Calcula que copiar para un restore, sin ejecutar nada. El bash hace la
    copia real (mas facil de auditar y de mantener atomica desde shell)."""
    manifest_path = os.path.join(args.snap_dir, "MANIFEST.json")
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    plan = []
    for row in manifest["sessions"]:
        if args.session and row["id"] != args.session and row["directory"] != args.session:
            continue
        rel = os.path.join("sessions", row["workspace"], row["directory"], row["artifact"])
        src = os.path.join(args.snap_dir, rel)
        dst = os.path.join(args.sessions, row["workspace"], row["directory"], row["artifact"])
        plan.append({"id": row["id"], "workspace": row["workspace"],
                     "directory": row["directory"], "src": src, "dst": dst})
    if args.session and not plan:
        raise SystemExit(f"la sesion '{args.session}' no esta en este snapshot")
    json.dump({"restores": plan}, sys.stdout, indent=2)
    print()
```

y su registro en `main()`:

```python
    p = sub.add_parser("restore-plan", help="calcula que copiar para un restore (uso interno)")
    p.add_argument("--snap-dir", required=True)
    p.add_argument("--sessions", required=True)
    p.add_argument("--session", default=None, help="limitar a una sesion (id o directory)")
    p.set_defaults(func=cmd_restore_plan)
```

- [ ] **Step 4: Agregar `restore` en bash**

En `dsh-manage.sh`, agregar después de `session_backup_verify()`:

```bash
# Espera opcional con timeout de que el puerto quede libre; NO se usa para
# esperar a que arranque (eso es wait_for_port), sino para el chequeo
# obligatorio de restore/repair.
require_dsh_stopped() {
  local pid
  pid="$(port_pid)"
  if [ -n "$pid" ]; then
    echo "dsh esta corriendo (pid $pid en :$DSH_PORT). Detenelo primero:" >&2
    echo "  systemctl stop dsh.service   # si esta gestionado por systemd" >&2
    echo "  dsh-manage stop               # si no" >&2
    return 1
  fi
}

# restore: copia sesiones desde un snapshot de vuelta a sessions/. La UNICA
# funcion de session-backup (junto con repair) que escribe ahi. Por eso:
# backup implicito antes, DSH detenido sin excepcion, escritura atomica.
session_backup_restore() {
  local from="latest" session="" force=0 to_new_id=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        [ $# -ge 2 ] || { echo "falta el valor de --from" >&2; return 1; }
        from="$2"; shift 2 ;;
      --session)
        [ $# -ge 2 ] || { echo "falta el valor de --session" >&2; return 1; }
        session="$2"; shift 2 ;;
      --force) force=1; shift ;;
      --to-new-id) to_new_id=1; shift ;;
      *) echo "opcion desconocida para restore: $1" >&2; return 1 ;;
    esac
  done

  session_backup_preflight || return 1
  require_dsh_stopped || return 1

  local snap="$DSH_BACKUP_ROOT/$from"
  [ -d "$snap" ] || { echo "snapshot no encontrado: $snap" >&2; return 1; }
  session_backup_verify_dir "$snap" || { echo "snapshot invalido, abortando restore" >&2; return 1; }

  # Backup implicito del estado actual ANTES de escribir. Reusa create().
  echo "creando backup del estado actual antes de restaurar..."
  session_backup_create --label "pre-restore-$(date -u +%Y%m%dT%H%M%SZ)" || {
    echo "fallo el backup previo; abortando restore sin tocar nada" >&2
    return 1
  }

  umask 077
  local sessions_dir="$DSH_HOME/sessions"
  local plan_args=("$DSH_MANAGE_DIR/plugins/session-scan.py" restore-plan --snap-dir "$snap" --sessions "$sessions_dir")
  [ -n "$session" ] && plan_args+=(--session "$session")
  local plan
  plan="$(python3 "${plan_args[@]}")" || return 1

  local count=0
  while IFS=$'\t' read -r src dst directory; do
    [ -n "$src" ] || continue
    if [ "$to_new_id" -eq 1 ]; then
      local new_dir
      new_dir="$(cd "$(dirname "$dst")/.." && pwd)/session-$(python3 -c 'import uuid; print(uuid.uuid4())')"
      mkdir -p "$new_dir"
      dst="$new_dir/$(basename "$dst")"
    fi
    if [ -e "$dst" ] && [ "$force" -eq 0 ] && [ "$to_new_id" -eq 0 ]; then
      local cur_sum snap_sum
      cur_sum="$(sha256sum "$dst" | cut -d' ' -f1)"
      snap_sum="$(sha256sum "$src" | cut -d' ' -f1)"
      if [ "$cur_sum" = "$snap_sum" ]; then
        continue  # ya identico, nada que hacer
      fi
    fi
    mkdir -p "$(dirname "$dst")"
    local tmp="${dst}.restore-tmp"
    cp "$src" "$tmp"
    mv -T "$tmp" "$dst"
    invalidate_projcache_entry "$directory" || true
    count=$((count + 1))
  done < <(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
for r in d['restores']:
    print(f\"{r['src']}\t{r['dst']}\t{r['directory']}\")
" "$plan")

  echo "restore completo: $count archivo(s) restaurado(s) desde $snap"
}

# Invalida la entrada de una sesion en la cache de proyeccion derivada
# (session_projcache.json). No-op silencioso si el archivo o la clave no
# existen -- la cache se repuebla sola. Ver spec S7.2.
invalidate_projcache_entry() {
  local session_id="$1"
  local cache="$DSH_HOME/storages/session_projcache.json"
  [ -f "$cache" ] || return 0
  python3 -c "
import json, os, sys
path = sys.argv[1]
sid = sys.argv[2]
with open(path, encoding='utf-8') as f:
    d = json.load(f)
sessions = d.get('tables', {}).get('sessions', {})
if sid not in sessions and not any(k.endswith(sid) or sid.endswith(k) for k in sessions):
    sys.exit(0)
keys_to_drop = [k for k in sessions if k == sid or k.endswith(sid) or sid.endswith(k)]
for k in keys_to_drop:
    del sessions[k]
tmp = path + '.tmp'
old_umask = os.umask(0o077)
try:
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f)
finally:
    os.umask(old_umask)
os.replace(tmp, path)
" "$cache" "$session_id"
}
```

Ampliar el despachador `session_backup()`:

```bash
    restore)  session_backup_restore "$@" ;;
```
y su línea de uso a `{scan|create|list|verify|restore}`.

- [ ] **Step 5: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio. Nota: el test de "exige DSH detenido" depende de que el bind a un puerto Python funcione en el sandbox de test — si `/dev/tcp` o el bind fallan por restricciones del entorno CI, el test debe saltearse con `skip` en vez de fallar falso-negativo; ajustar si hace falta pero mantener la assertion de fondo (rc≠0 con DSH corriendo).

- [ ] **Step 6: Verificar contra el host real (con cuidado — toca sesiones reales)**

**No correr `restore` contra el `$HOME/.dsh` real sin haber detenido `dsh.service` primero**, y solo con un snapshot de prueba, nunca reemplazando una sesión real sin backup fresco:

```bash
cd /opt/dsh-manage
./dsh-manage.sh session-backup create --label antes-de-probar-restore
systemctl stop dsh.service
./dsh-manage.sh session-backup restore --from latest --session <un-id-de-sesion-de-prueba>
systemctl start dsh.service
./dsh-manage.sh session-backup verify --from latest
```
Expected: `restore completo: N archivo(s) restaurado(s)`, el servicio vuelve a levantar (`wait_for_port` implícito al reiniciar). Si algo sale mal, el snapshot `antes-de-probar-restore` permite volver atrás con otro `restore`.

- [ ] **Step 7: Commit**

```bash
git add plugins/session-scan.py dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): subcomando restore"
```

---

### Task 2: `prune`

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `DSH_BACKUP_ROOT`, formato de nombre de snapshot (`<UTC>-<label>`, ordena lexicográficamente = cronológicamente).
- Produces: `session_backup_prune()`.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "prune sin --yes no borra nada" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-p1--" "session-p1" "session-p1" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label uno
  sleep 1.1
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label dos
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup prune --keep 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* ]]
  count="$(find "$DSH_BACKUP_ROOT" -maxdepth 1 -type d ! -name '*.partial' ! -name "$(basename "$DSH_BACKUP_ROOT")" | wc -l)"
  [ "$count" -eq 2 ]
}

@test "prune --keep conserva los N mas recientes" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-p2--" "session-p2" "session-p2" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label viejo
  sleep 1.1
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label nuevo
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup prune --keep 1 --yes
  [ "$status" -eq 0 ]
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup list
  [[ "$output" == *"nuevo"* ]]
  [[ "$output" != *"viejo"* ]]
}

@test "prune nunca borra el unico backup de una sesion broken" {
  install_fake_harness 48
  # sesion con un tipo desconocido sin dueno -> broken
  fake_session "$DSH_HOME/sessions" "--ws-p3--" "session-p3" "session-p3" \
    '{"type":"foo/inventado","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label unico-broken
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup prune --keep 0 --yes
  [ "$status" -eq 0 ]
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup list
  [[ "$output" == *"unico-broken"* ]]
}

@test "prune --older-than borra por edad" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-p4--" "session-p4" "session-p4" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label reciente
  # forzamos un snapshot "viejo" renombrando el directorio con timestamp antiguo
  snap="$(ls -d "$DSH_BACKUP_ROOT"/*-reciente)"
  viejo="$DSH_BACKUP_ROOT/20200101T000000Z-viejo-de-verdad"
  cp -r "$snap" "$viejo"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup prune --older-than 30 --yes
  [ "$status" -eq 0 ]
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup list
  [[ "$output" != *"viejo-de-verdad"* ]]
  [[ "$output" == *"reciente"* ]]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `prune` no es un subcomando válido.

- [ ] **Step 3: Escribir la implementación**

Agregar a `dsh-manage.sh`, después de `session_backup_restore()`:

```bash
# prune: borra snapshots viejos por retencion. NUNCA escribe bajo sessions/;
# solo borra directorios de snapshot. Nunca borra el UNICO backup que cubre
# una sesion broken (perderia la unica copia recuperable).
session_backup_prune() {
  local keep=10 older_than="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep)
        [ $# -ge 2 ] || { echo "falta el valor de --keep" >&2; return 1; }
        keep="$2"; shift 2 ;;
      --older-than)
        [ $# -ge 2 ] || { echo "falta el valor de --older-than" >&2; return 1; }
        older_than="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) echo "opcion desconocida para prune: $1" >&2; return 1 ;;
    esac
  done

  if [ "$yes" -ne 1 ]; then
    echo "prune requiere --yes para borrar de verdad (dry-run no implementado en esta version)" >&2
    return 1
  fi

  [ -d "$DSH_BACKUP_ROOT" ] || { echo "no hay snapshots ($DSH_BACKUP_ROOT no existe)"; return 0; }

  # Candidatos: directorios completos (no .partial, no 'latest'), orden
  # cronologico por nombre (UTC ISO basico ordena lexicograficamente).
  local candidates=()
  local dir
  for dir in "$DSH_BACKUP_ROOT"/*/; do
    [ -d "$dir" ] || continue
    case "${dir%/}" in *.partial|*/latest) continue ;; esac
    [ -f "${dir}MANIFEST.json" ] || continue
    candidates+=("${dir%/}")
  done
  IFS=$'\n' candidates=($(printf '%s\n' "${candidates[@]}" | sort))
  unset IFS

  local total=${#candidates[@]}
  local to_delete=()
  local i
  if [ -n "$older_than" ]; then
    local cutoff
    cutoff="$(date -u -d "-${older_than} days" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -v-"${older_than}"d +%Y%m%dT%H%M%SZ)"
    for dir in "${candidates[@]}"; do
      local name; name="$(basename "$dir")"
      [[ "$name" < "$cutoff" ]] && to_delete+=("$dir")
    done
  else
    if [ "$total" -gt "$keep" ]; then
      local n_delete=$((total - keep))
      for ((i = 0; i < n_delete; i++)); do
        to_delete+=("${candidates[$i]}")
      done
    fi
  fi

  local deleted=0 protected=0
  for dir in "${to_delete[@]}"; do
    local has_broken
    has_broken="$(python3 -c "
import json
try:
    m = json.load(open('$dir/MANIFEST.json'))
except Exception:
    print('0'); raise SystemExit
print('1' if any(s.get('risk') == 'broken' for s in m.get('sessions', [])) else '0')
")"
    if [ "$has_broken" = "1" ]; then
      # Es el unico backup de una sesion broken si ningun OTRO snapshot
      # sobreviviente (fuera de to_delete) tiene la misma sesion.
      local sid unique=1
      for sid in $(python3 -c "
import json
m = json.load(open('$dir/MANIFEST.json'))
print(' '.join(s['id'] for s in m['sessions'] if s.get('risk') == 'broken'))
"); do
        local other
        for other in "${candidates[@]}"; do
          [ "$other" = "$dir" ] && continue
          local will_delete=0 d2
          for d2 in "${to_delete[@]}"; do [ "$d2" = "$other" ] && will_delete=1; done
          [ "$will_delete" -eq 1 ] && continue
          if python3 -c "
import json, sys
m = json.load(open('$other/MANIFEST.json'))
sys.exit(0 if any(s['id'] == '$sid' for s in m['sessions']) else 1)
" 2>/dev/null; then
            unique=0
          fi
        done
      done
      if [ "$unique" -eq 1 ]; then
        protected=$((protected + 1))
        echo "protegido (unico backup de sesion broken): $(basename "$dir")"
        continue
      fi
    fi
    rm -rf -- "$dir"
    deleted=$((deleted + 1))
  done

  echo "prune: $deleted snapshot(s) borrado(s), $protected protegido(s) por ser el unico backup de una sesion broken"
}
```

Ampliar el despachador:

```bash
    prune)    session_backup_prune "$@" ;;
```
y su línea de uso a `{scan|create|list|verify|restore|prune}`.

- [ ] **Step 4: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 5: Verificar contra el host real**

```bash
cd /opt/dsh-manage
./dsh-manage.sh session-backup list
./dsh-manage.sh session-backup prune --keep 5 --yes
./dsh-manage.sh session-backup list
```
Expected: conserva los 5 snapshots más recientes (o los que haya si son menos), protege cualquiera que sea el único backup de una sesión `broken`.

- [ ] **Step 6: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): subcomando prune"
```

---

### Task 3: `session_backup_guard` (gate compartido)

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_scan()`, `session_backup_create()`, `scan_plugin_vocabulary()` (vía `session-scan.py`).
- Produces: `session_backup_guard()` — función de biblioteca (no subcomando de usuario), pensada para que `plugins_install()`/`plugins_remove()` la invoquen.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "session_backup_guard detecta cuando un paquete a remover deja sesiones broken" {
  install_fake_harness 48
  nm="$BATS_TEST_TMPDIR/nm-guard"
  fake_plugin "$nm" "plugin-guard-test" "guard/evento"
  fake_session "$DSH_HOME/sessions" "--ws-g1--" "session-g1" "session-g1" \
    '{"type":"guard/evento","seq":1,"time":1,"data":{}}'
  source <(sed -n '/^session_backup_preflight/,/^}/p; /^dsh_session_lib_path/,/^}/p; /^session_backup_guard/,/^}/p' "$BATS_TEST_DIRNAME/../dsh-manage.sh")
  export DSH_PREFIX="$DSH_NODE/.." DSH_PKG="@deepseek-ai/dsh" DSH_MANAGE_DIR="$BATS_TEST_DIRNAME/.."
  run session_backup_guard remove "$nm/plugin-guard-test" web
  [ "$status" -eq 3 ]  # 3 = hay sesiones que pasarian a broken
  [[ "$output" == *"session-g1"* ]] || [[ "$output" == *"1"* ]]
}

@test "session_backup_guard no bloquea cuando no hay sesiones afectadas" {
  install_fake_harness 48
  nm="$BATS_TEST_TMPDIR/nm-guard2"
  fake_plugin "$nm" "plugin-sin-uso" "sinuso/evento"
  source <(sed -n '/^session_backup_preflight/,/^}/p; /^dsh_session_lib_path/,/^}/p; /^session_backup_guard/,/^}/p' "$BATS_TEST_DIRNAME/../dsh-manage.sh")
  export DSH_PREFIX="$DSH_NODE/.." DSH_PKG="@deepseek-ai/dsh" DSH_MANAGE_DIR="$BATS_TEST_DIRNAME/.."
  run session_backup_guard remove "$nm/plugin-sin-uso" web
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `session_backup_guard` no existe.

- [ ] **Step 3: Escribir la implementación**

Agregar a `dsh-manage.sh`, después de `session_backup_prune()`:

```bash
# Gate compartido invocado por plugins_install()/plugins_remove(). Calcula el
# impacto de instalar/remover un paquete sobre las sesiones existentes.
# Devuelve por stdout un resumen legible y por exit code:
#   0 = sin impacto, seguir sin backup
#   2 = impacto detectado, backup ya hecho (create automatico corrido adentro)
#   3 = impacto detectado y es indispensable confirmar antes de seguir
# accion: "install" | "remove". pkg_dir: directorio del paquete (para leer su
# lib/*.js y extraer vocabulario, igual que scan_plugin_vocabulary). profile:
# nombre del profile afectado.
session_backup_guard() {
  local accion="$1" pkg_dir="$2" profile="$3"
  session_backup_preflight || return 1

  local sessions_dir="$DSH_HOME/sessions"
  [ -d "$sessions_dir" ] || return 0

  # Vocabulario del paquete en cuestion, aislado (no todo node_modules).
  local pkg_types
  pkg_types="$(python3 - "$pkg_dir" <<'PY'
import sys, os, re, json
sys.path.insert(0, os.environ.get("DSH_MANAGE_DIR", ".") + "/plugins")
APPEND_LITERAL = re.compile(r'append\(\s*"([a-z][a-z0-9-]*/[a-z0-9/-]+)"')
VOCAB_MARKER = "KNOWN_SESSION_EVENT_TYPES"
pkg_dir = sys.argv[1]
lib = os.path.join(pkg_dir, "lib")
types = set()
if os.path.isdir(lib):
    for root, _, files in os.walk(lib):
        for name in files:
            if not name.endswith(".js"):
                continue
            try:
                with open(os.path.join(root, name), encoding="utf-8", errors="replace") as f:
                    src = f.read()
            except OSError:
                continue
            if VOCAB_MARKER not in src:
                continue
            types.update(APPEND_LITERAL.findall(src))
print("\n".join(sorted(types)))
PY
)"
  if [ -z "$pkg_types" ]; then
    return 0  # el paquete no declara vocabulario: sin impacto posible
  fi

  local scan_args=(
    "$DSH_MANAGE_DIR/plugins/session-scan.py" scan
    --sessions "$sessions_dir"
    --harness "$(dsh_session_lib_path)"
  )
  local profile_nm="$DSH_HOME/profiles/$profile/node_modules"
  [ -d "$profile_nm" ] && scan_args+=(--profile-node-modules "$profile_nm")
  local scan_json
  scan_json="$(python3 "${scan_args[@]}")" || return 1

  local affected
  affected="$(python3 -c "
import json, sys
scan = json.loads(sys.argv[1])
pkg_types = set(sys.argv[2].splitlines())
accion = sys.argv[3]
hits = []
for s in scan['sessions']:
    types_here = {u['type'] for u in s.get('unknownTypes', [])}
    if accion == 'remove':
        # tipos que este paquete DECLARA y esta sesion USA -> pasarian a broken
        if types_here & pkg_types:
            hits.append(s['id'])
    else:
        # instalar/actualizar: riesgo menor, mismo chequeo hoy
        if types_here & pkg_types:
            hits.append(s['id'])
print(len(hits))
for h in hits:
    print(h)
" "$scan_json" "$pkg_types" "$accion")"

  local n_affected
  n_affected="$(echo "$affected" | head -1)"
  if [ "$n_affected" -eq 0 ] 2>/dev/null; then
    return 0
  fi

  echo "⚠ esta operacion ($accion) afecta a $n_affected sesion(es):"
  echo "$affected" | tail -n +2 | sed 's/^/    /'
  echo "$scan_json" > "${DSH_BACKUP_ROOT:-$DSH_HOME/session-backups}/.last-guard-scan.json.tmp" 2>/dev/null || true
  return 3
}
```

- [ ] **Step 4: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 5: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): gate compartido session_backup_guard"
```

---

### Task 4: `plugins_remove()` con restart mitigado

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_guard()` (Task 3), `session_backup_create()`, `port_pid()`/`wait_for_port()` (ya existen), `dsh_service_manages_this_home()` (ya existe).
- Produces: `restart_dsh()` (extraída del bloque duplicado que hoy vive dentro de `plugins_install()`), `plugins_remove()`, dispatcher `plugins-remove`.

> ⚠️ **Esta es la tarea más sensible de todo este plan.** `plugins_remove()` reinicia `dsh.service` — a diferencia del patch de `dsh-swarm-panel` en la v1 de Fase 1+2 (que era un no-op inútil), acá el restart es necesario y tiene efecto real. Mitigaciones obligatorias: backup automático antes, confirmación explícita (aborta sin `--yes` y sin TTY), verificación post-restart igual que `plugins_install` ya hace.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "plugins_remove sin --yes y sin TTY aborta sin tocar nada" {
  install_fake_harness 48
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" plugins-remove paquete-inexistente web < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* ]] || [[ "$output" == *"TTY"* ]]
}

@test "plugins_remove con --yes pero paquete no instalado falla limpio" {
  install_fake_harness 48
  mkdir -p "$DSH_HOME/profiles/web"
  echo '{"name":"web","dependencies":{}}' > "$DSH_HOME/profiles/web/package.json"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" plugins-remove paquete-que-no-existe web --yes
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `plugins-remove` no está en el dispatcher.

- [ ] **Step 3: Extraer `restart_dsh()` de `plugins_install()`**

En `dsh-manage.sh`, dentro de `plugins_install()`, reemplazar el bloque:

```bash
  echo "reiniciando dsh para activar el stack..."
  if dsh_service_manages_this_home; then
    systemctl restart dsh.service
    sleep 3
  else
    stop || true
    sleep 1
    start
  fi

  if ! wait_for_port; then
    echo "dsh no quedó escuchando en :$DSH_PORT tras instalar los plugins, ver $DSH_LOG" >&2
    return 1
  fi

  echo "boot OK, verificando errores conocidos en el log..."
  if grep -qiE 'duplicate|failed to load|cannot find package|EADDRINUSE' "$DSH_LOG"; then
    echo "⚠ se encontraron mensajes de error conocidos en $DSH_LOG — revisar antes de dar por bueno" >&2
    grep -iE 'duplicate|failed to load|cannot find package|EADDRINUSE' "$DSH_LOG" | tail -20
    return 1
  fi
```

por:

```bash
  restart_dsh || return 1
```

Y agregar la función `restart_dsh()`, justo antes de `plugins_install() {`:

```bash
# Reinicia dsh y verifica que vuelva a levantar sano. Compartida por
# plugins_install() y plugins_remove() -- antes vivia duplicada solo en
# plugins_install(); un cambio hecho en una copia no se propagaba a la otra.
restart_dsh() {
  echo "reiniciando dsh para activar los cambios..."
  if dsh_service_manages_this_home; then
    systemctl restart dsh.service
    sleep 3
  else
    stop || true
    sleep 1
    start
  fi

  if ! wait_for_port; then
    echo "dsh no quedó escuchando en :$DSH_PORT tras el restart, ver $DSH_LOG" >&2
    return 1
  fi

  echo "boot OK, verificando errores conocidos en el log..."
  if grep -qiE 'duplicate|failed to load|cannot find package|EADDRINUSE' "$DSH_LOG"; then
    echo "⚠ se encontraron mensajes de error conocidos en $DSH_LOG — revisar antes de dar por bueno" >&2
    grep -iE 'duplicate|failed to load|cannot find package|EADDRINUSE' "$DSH_LOG" | tail -20
    return 1
  fi
}
```

- [ ] **Step 4: Escribir `plugins_remove()`**

Agregar justo después de `plugins_install()`:

```bash
# Remueve un paquete de un profile con el gate de session-backup como
# obligatorio en el medio. Es la direccion que causo el incidente original
# (dsh-swarm-panel desinstalado sin aviso rompio sesiones reales) -- por eso
# el backup automatico y la confirmacion NO son opcionales.
plugins_remove() {
  local pkg="${1:-}" profile="${2:-web}"
  shift 2 2>/dev/null || true
  local yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) echo "opcion desconocida para plugins-remove: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$pkg" ]; then
    echo "uso: $0 plugins-remove <paquete> [profile] [--yes]" >&2
    return 1
  fi

  local profile_dir="$DSH_HOME/profiles/$profile"
  if [ ! -d "$profile_dir" ]; then
    echo "profile no encontrado: $profile_dir" >&2
    return 1
  fi
  if [ ! -f "$profile_dir/package.json" ]; then
    echo "sin package.json en $profile_dir — nada que remover" >&2
    return 1
  fi
  if ! node -e "
    const pkg = require('$profile_dir/package.json');
    const has = (pkg.dependencies && pkg.dependencies['$pkg']) ||
                (pkg.devDependencies && pkg.devDependencies['$pkg']);
    process.exit(has ? 0 : 1);
  " 2>/dev/null; then
    echo "'$pkg' no esta instalado en el profile '$profile'" >&2
    return 1
  fi

  local pkg_dir="$profile_dir/node_modules/$pkg"
  local guard_rc=0
  if [ -d "$pkg_dir" ]; then
    session_backup_guard remove "$pkg_dir" "$profile"
    guard_rc=$?
  fi

  if [ "$guard_rc" -eq 3 ]; then
    echo "creando backup automatico antes de continuar (trigger: plugins-remove)..."
    DSH_TRIGGER="plugins-remove" session_backup_create --only-at-risk \
      --label "preremove-$(echo "$pkg" | tr -c 'A-Za-z0-9._-' '-')" || {
      echo "fallo el backup automatico; abortando plugins-remove" >&2
      return 1
    }
    echo
    echo "opciones tras remover '$pkg':"
    echo "  a) reinstalar el plugin para volver a leer esas sesiones"
    echo "  b) dsh-manage session-backup repair --session <id> --mark-ignorable"
    echo "     (las sesiones cargan, los eventos de ese plugin se omiten)"
    echo
    if [ "$yes" -ne 1 ]; then
      if [ ! -t 0 ]; then
        echo "sin --yes y sin TTY: abortando sin remover nada" >&2
        return 1
      fi
      read -r -p "¿remover '$pkg' de todas formas? [y/N] " confirm
      case "$confirm" in
        y|Y|yes|si|s) : ;;
        *) echo "cancelado"; return 1 ;;
      esac
    fi
  elif [ "$yes" -ne 1 ] && [ ! -t 0 ]; then
    # Sin impacto detectado pero igual sin --yes y sin TTY: no removemos
    # nada en modo no interactivo sin confirmacion explicita.
    echo "sin --yes y sin TTY: abortando sin remover nada" >&2
    return 1
  fi

  echo "removiendo '$pkg' del profile '$profile'..."
  (cd "$profile_dir" && PATH="$DSH_NODE:$PATH" pnpm remove "$pkg") \
    || { echo "pnpm remove falló, ver arriba" >&2; return 1; }

  restart_dsh || return 1

  echo "verificando el impacto real tras el restart..."
  session_backup_scan --fail-on-risk >/dev/null 2>&1
  local post_rc=$?
  if [ "$post_rc" -eq 4 ]; then
    echo "⚠ hay sesiones 'broken' tras remover '$pkg'. Backup disponible con 'dsh-manage session-backup list'." >&2
  fi

  echo "listo: '$pkg' removido del profile '$profile'"
}
```

Agregar al dispatcher, justo después de `plugins-install)`:

```bash
  plugins-remove)   plugins_remove "${2:-}" "${3:-web}" "${@:4}" ;;
```
y actualizar la línea de uso.

- [ ] **Step 5: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 6: Verificar contra el host real — SOLO en un profile descartable**

**No correr esto contra el profile `web` de producción.** Usar el profile `repro` (ya existe, ya se usó para el gate de `repair`):

```bash
cd /opt/dsh-manage
./dsh-manage.sh plugins-remove dsh-defend repro --yes 2>&1 | tail -20
# revertir para dejar repro como estaba:
(cd "$HOME/.dsh/profiles/repro" && PATH="$HOME/.local/dsh-node/node24/bin:$PATH" pnpm install)
```
Expected: el `guard` corre, si `dsh-defend` no declara vocabulario de sesión el `guard_rc` es 0 y remueve directo; `pnpm remove` sale limpio; `restart_dsh` no aplica si `repro` no es el profile activo del `dsh.service` (confirmar con `dsh_service_manages_this_home` antes — si `repro` no es el `WorkingDirectory` del unit, este restart no toca producción).

- [ ] **Step 7: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): plugins_remove con gate de resguardo obligatorio"
```

---

### Task 5: Hook de `session_backup_guard` en `plugins_install()`

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_guard()` (Task 3).
- Produces: modificación de `plugins_install()` existente (sin cambiar su firma).

- [ ] **Step 1: Escribir el test que falla**

Agregar a `tests/session-backup.bats`:

```bash
@test "plugins_install corre scan post-install y avisa si aparecen broken" {
  # Test de humo: confirma que la funcion sigue siendo invocable y no rompe
  # el flujo existente cuando no hay manifest (fast-fail esperado, ya
  # cubierto por tests/dsh-manage.bats -- aca solo confirmamos que el nuevo
  # bloque de post-check no introduce un error de sintaxis bash.
  install_fake_harness 48
  run bash -n "$BATS_TEST_DIRNAME/../dsh-manage.sh"
  [ "$status" -eq 0 ]
}
```

(El comportamiento funcional completo de `plugins_install()` con el manifest real ya está cubierto por `tests/dsh-manage.bats`; este test es deliberadamente mínimo — confirma sintaxis, no reimplementa esos tests.)

- [ ] **Step 2: Correr el test para ver que pasa incluso antes del cambio**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats -f "plugins_install corre scan"`
Expected: PASS (test de sintaxis, no depende del cambio todavía — se agrega ahora para que la Task 6 self-review pueda confirmarlo después del cambio también).

- [ ] **Step 3: Agregar el post-check a `plugins_install()`**

Dentro de `plugins_install()`, inmediatamente después del bloque que ahora es `restart_dsh || return 1` (de la Task 4), agregar:

```bash
  echo "revisando el impacto del stack instalado sobre las sesiones existentes..."
  local scan_rc=0
  session_backup_scan "$profile" --fail-on-risk >/dev/null 2>&1 || scan_rc=$?
  if [ "$scan_rc" -eq 4 ]; then
    echo "⚠ hay sesiones 'broken' tras instalar el stack. Corré 'dsh-manage session-backup scan' para el detalle." >&2
  elif [ "$scan_rc" -eq 3 ]; then
    echo "ℹ hay sesiones 'at-risk' (dependen de un plugin recién instalado). Considerá 'dsh-manage session-backup create --only-at-risk'." >&2
  fi
```

- [ ] **Step 4: Correr los tests**

Run: `cd /opt/dsh-manage && bats tests/ && make check`
Expected: PASS — incluidos los tests de `tests/dsh-manage.bats` que ya cubrían `plugins_install`.

- [ ] **Step 5: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): post-check de riesgo tras plugins-install"
```

---

### Task 6: `repair --mark-ignorable`

**Files:**
- Modify: `plugins/session-scan.py`
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `require_dsh_stopped()`, `session_backup_create()`, `invalidate_projcache_entry()` (Task 1); `load_baseline()`, `CHUNK_ROW_TAGS` (Fase 1+2).
- Produces: `repair_events()` (Python, pura), CLI `session-scan.py repair --artifact <ruta> --harness <ruta> --out <ruta> [--types <a,b>]`, `session_backup_repair()` (bash).

> Gate ya superado (spec §7.3): esta tarea implementa lo que ya se validó manualmente contra la sesión real de `vpn-monitor-mke`.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "repair marca solo los tipos desconocidos, copia el resto byte a byte" {
  install_fake_harness 48
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-rp1--" "session-rp1" "session-rp1" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{"x":  1}}' \
    '{"type":"foo/desconocido","seq":2,"time":2,"data":{}}' \
    '{"type":"tipo/2","seq":3,"time":3,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-repair-rp1
  run env DSH_PORT=39222 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --session session-rp1 --mark-ignorable --yes
  [ "$status" -eq 0 ]
  # el evento marcado debe tener ignorable:true; los otros deben seguir igual
  run bash -c "zstd -dc '$DSH_HOME/sessions/--ws-rp1--/session-rp1/session.jsonl.zstd' | sed -n '3p'"
  [[ "$output" == *'"ignorable": true'* ]] || [[ "$output" == *'"ignorable":true'* ]]
  # la primera linea de datos (tipo/1) debe seguir teniendo el espacio raro
  # original (prueba de que no se re-serializo)
  run bash -c "zstd -dc '$DSH_HOME/sessions/--ws-rp1--/session-rp1/session.jsonl.zstd' | sed -n '2p'"
  [[ "$output" == *'"x":  1'* ]]
}

@test "repair exige DSH detenido" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-rp2--" "session-rp2" "session-rp2" \
    '{"type":"foo/x","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-rp2
  python3 -c "
import socket, os
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 39223))
s.listen(1)
if os.fork() == 0:
    s.accept()
else:
    import time; time.sleep(0.3)
" &
  sleep 0.2
  run env DSH_PORT=39223 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --session session-rp2 --mark-ignorable --yes
  kill %1 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "repair sin --session falla (nunca en lote)" {
  install_fake_harness 48
  run env DSH_PORT=39224 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --mark-ignorable --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"--session"* ]]
}

@test "repair hace backup implicito antes de tocar la sesion" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-rp3--" "session-rp3" "session-rp3" \
    '{"type":"foo/x","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-rp3
  before_count="$(find "$DSH_BACKUP_ROOT" -maxdepth 1 -type d ! -name '*.partial' | wc -l)"
  run env DSH_PORT=39225 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --session session-rp3 --mark-ignorable --yes
  [ "$status" -eq 0 ]
  after_count="$(find "$DSH_BACKUP_ROOT" -maxdepth 1 -type d ! -name '*.partial' | wc -l)"
  [ "$after_count" -gt "$before_count" ]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `repair` no es un subcomando válido.

- [ ] **Step 3: Agregar `repair_events` al helper Python**

Agregar a `plugins/session-scan.py`, antes de `main()`:

```python
def repair_events(artifact, baseline, allowed_types=None):
    """Marca ignorable:true SOLO en lineas cuyo tipo esta fuera del baseline
    (y opcionalmente restringido a allowed_types). Copia byte a byte todo lo
    demas -- NUNCA re-serializa una linea que no se marca (round-trip de
    json.dumps cambia whitespace/orden aunque el contenido sea igual, lo que
    violaria "copiar byte a byte lo no tocado").

    Devuelve (lineas_de_salida, cantidad_marcada). No escribe ningun archivo:
    el llamador decide donde y como persistir (temp + mv atomico).
    """
    if artifact.endswith(".zstd"):
        raw = subprocess.run(["zstd", "-dc", artifact], capture_output=True).stdout.decode("utf-8", errors="replace")
    else:
        with open(artifact, encoding="utf-8", errors="replace") as f:
            raw = f.read()
    lines = raw.splitlines()
    out = []
    marked = 0
    for line in lines:
        if not line.strip():
            out.append(line)
            continue
        try:
            row = json.loads(line)
        except ValueError:
            out.append(line)  # cola rota: se copia tal cual, no se toca
            continue
        kind = row.get("type")
        is_chunk_row = kind in CHUNK_ROW_TAGS
        already_ok = kind in baseline or row.get("ignorable") is True or is_chunk_row
        if already_ok:
            out.append(line)  # BYTE A BYTE, sin re-serializar
            continue
        if allowed_types is not None and kind not in allowed_types:
            out.append(line)  # fuera del filtro --types: no se toca
            continue
        row["ignorable"] = True
        out.append(json.dumps(row, ensure_ascii=False))
        marked += 1
    return out, marked


def cmd_repair(args):
    baseline = load_baseline(args.harness)
    allowed = set(args.types.split(",")) if args.types else None
    lines, marked = repair_events(args.artifact, baseline, allowed)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{marked} eventos marcados ignorable:true")
```

y su registro en `main()`:

```python
    p = sub.add_parser("repair", help="marca eventos huerfanos como ignorable (uso interno)")
    p.add_argument("--artifact", required=True)
    p.add_argument("--harness", required=True)
    p.add_argument("--out", required=True, help="ruta del jsonl plano de salida")
    p.add_argument("--types", default=None, help="lista separada por comas; restringe a estos tipos")
    p.set_defaults(func=cmd_repair)
```

- [ ] **Step 4: Escribir `session_backup_repair()` en bash**

Agregar a `dsh-manage.sh`, después de `plugins_remove()`:

```bash
# repair: marca eventos huerfanos como ignorable:true, in-place, para que la
# sesion cargue sin el plugin que los escribio. Lossy (esos eventos dejan de
# interpretarse) y se dice sin eufemismos en la salida. Nunca en lote.
session_backup_repair() {
  local session="" mark_ignorable=0 types="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --session)
        [ $# -ge 2 ] || { echo "falta el valor de --session" >&2; return 1; }
        session="$2"; shift 2 ;;
      --mark-ignorable) mark_ignorable=1; shift ;;
      --types)
        [ $# -ge 2 ] || { echo "falta el valor de --types" >&2; return 1; }
        types="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) echo "opcion desconocida para repair: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$session" ]; then
    echo "repair requiere --session (nunca opera en lote por default)" >&2
    return 1
  fi
  if [ "$mark_ignorable" -ne 1 ]; then
    echo "repair requiere --mark-ignorable (unico modo hoy, explicito)" >&2
    return 1
  fi
  if [ "$yes" -ne 1 ]; then
    echo "repair requiere --yes: los eventos marcados DEJAN DE INTERPRETARSE (lossy)" >&2
    return 1
  fi

  session_backup_preflight || return 1
  require_dsh_stopped || return 1

  local sessions_dir="$DSH_HOME/sessions"
  local artifact
  artifact="$(find "$sessions_dir" -type d -name "$session" -print -quit 2>/dev/null)"
  if [ -z "$artifact" ]; then
    # tambien aceptar buscar por el id del header, no solo el nombre de dir
    artifact="$(grep -rl "\"id\":\"$session\"" "$sessions_dir" 2>/dev/null | head -1)"
    [ -n "$artifact" ] && artifact="$(dirname "$artifact")"
  fi
  if [ -z "$artifact" ]; then
    echo "no se encontro la sesion '$session' bajo $sessions_dir" >&2
    return 1
  fi
  local artifact_file
  for f in "session.jsonl.zstd" "session.jsonl"; do
    [ -f "$artifact/$f" ] && artifact_file="$artifact/$f"
  done
  [ -n "${artifact_file:-}" ] || { echo "sin artefacto de sesion en $artifact" >&2; return 1; }

  echo "creando backup antes de reparar..."
  session_backup_create --label "pre-repair-$(basename "$session")-$(date -u +%Y%m%dT%H%M%SZ)" || {
    echo "fallo el backup previo; abortando repair sin tocar nada" >&2
    return 1
  }

  umask 077
  local out_plain="${artifact_file}.repair-plain"
  local repair_args=(
    "$DSH_MANAGE_DIR/plugins/session-scan.py" repair
    --artifact "$artifact_file"
    --harness "$(dsh_session_lib_path)"
    --out "$out_plain"
  )
  [ -n "$types" ] && repair_args+=(--types "$types")
  local repair_output
  repair_output="$(python3 "${repair_args[@]}")" || { rm -f "$out_plain"; return 1; }
  echo "$repair_output"

  local new_zstd="${artifact_file}.repair-tmp"
  if [[ "$artifact_file" == *.zstd ]]; then
    zstd -q -f -o "$new_zstd" "$out_plain"
  else
    cp "$out_plain" "$new_zstd"
  fi
  rm -f "$out_plain"

  # Validacion final antes de publicar in-place.
  if [[ "$new_zstd" == *.zstd ]]; then
    zstd -t "$new_zstd" >/dev/null 2>&1 || { echo "el archivo reparado no valida (zstd -t), abortando" >&2; rm -f "$new_zstd"; return 1; }
  fi

  mv -T "$new_zstd" "$artifact_file"
  invalidate_projcache_entry "$(basename "$artifact")" || true

  echo "repair completo sobre $artifact_file"
}
```

Ampliar el despachador:

```bash
    repair)   session_backup_repair "$@" ;;
```
y su línea de uso a `{scan|create|list|verify|restore|prune|repair}`.

- [ ] **Step 5: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 6: Re-confirmar el gate contra la sesión real** (ya hecho manualmente en §7.3, repetirlo ahora vía el comando real)

```bash
cd /opt/dsh-manage
./dsh-manage.sh session-backup create --label antes-de-repair-real
systemctl stop dsh.service
./dsh-manage.sh session-backup repair --session session-67436620-4931-423a-aeac-3b7eb7b03ec9 --mark-ignorable --yes
systemctl start dsh.service
```
Expected: `N eventos marcados ignorable:true` con N cercano a 80 (el número exacto puede variar levemente si el corpus cambió). Verificar después que la sesión sigue siendo legible por el harness (mismo chequeo del gate §7.3: `decodeStorageRecord` + `KNOWN_SESSION_EVENT_TYPES` da 0 rechazados).

- [ ] **Step 7: Commit**

```bash
git add plugins/session-scan.py dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): subcomando repair --mark-ignorable"
```

---

### Task 7: Versión y documentación

**Files:**
- Modify: `dsh-manage.sh` (línea de versión), `CHANGELOG.md`, `README.md`
- Test: `tests/session-backup.bats`

- [ ] **Step 1: Bump de versión**

En `dsh-manage.sh`, buscar la línea exacta con `grep -n 'DSH_MANAGE_VERSION='` (hoy dice `"1.2.0"`) y cambiarla a:

```bash
DSH_MANAGE_VERSION="1.3.0"
```

- [ ] **Step 2: CHANGELOG**

Insertar inmediatamente antes de la línea `## [1.2.0] - 2026-08-25` (buscar con `grep -n '^## \[1.2.0\]'`):

```markdown
## [Unreleased]

### Agregado

- `dsh-manage session-backup restore` — restaura sesiones desde un snapshot,
  con backup implícito previo, exige DSH detenido, escritura atómica.
  `--session` limita a una sola sesión, `--to-new-id` restaura como sesión
  nueva sin pisar la original, `--force` sobreescribe aunque difiera.
- `dsh-manage session-backup prune` — borra snapshots viejos por retención
  (`--keep` / `--older-than`), nunca borra el único backup que cubre una
  sesión `broken`. Requiere `--yes` explícito.
- `dsh-manage session-backup repair --mark-ignorable` — marca eventos
  huérfanos como `ignorable:true` in-place para que una sesión cargue sin el
  plugin que los escribió. Lossy (esos eventos dejan de interpretarse),
  nunca en lote (`--session` obligatorio), copia byte a byte todo lo que no
  marca. Gate de validación superado contra la sesión real de
  `vpn-monitor-mke` antes de implementar (ver `docs/SESSION-BACKUP-DESIGN.md`
  §7.3).
- `dsh-manage plugins-remove <paquete> [profile] [--yes]` — nuevo comando que
  cierra la causa raíz del incidente original: antes de un `pnpm remove`,
  corre el gate de resguardo (`session_backup_guard`), hace backup automático
  si detecta impacto, y exige confirmación explícita (aborta sin `--yes` y
  sin TTY). Reinicia `dsh.service` con la misma verificación post-restart que
  `plugins-install` ya usa.
- `plugins-install` corre un chequeo de riesgo post-instalación y avisa si
  aparecen sesiones `at-risk`/`broken` tras el stack instalado.
- Invalidación de `session_projcache.json` en `restore`/`repair`: se borra
  solo la clave de la sesión tocada, las demás se preservan (spec §7.2).

### Cambiado

- `restart_dsh()` extraída de `plugins_install()` para compartirla con
  `plugins_remove()` — antes vivía duplicada solo en un lugar.
```

- [ ] **Step 3: README**

Ampliar la tabla de comandos (buscar la fila de `session-backup` ya existente y reemplazarla):

```markdown
| `session-backup {scan,create,list,verify,restore,prune,repair}` | Resguardo de sesiones: clasifica riesgo, crea/restaura/repara snapshots |
| `plugins-remove <paquete> [profile] [--yes]` | Remueve un plugin con gate de resguardo automático |
```

Ampliar la sección `### session-backup: resguardo de sesiones` (buscar con `grep -n '^### .session-backup'`), agregando después de la tabla `ok`/`at-risk`/`broken` existente:

````markdown
```bash
dsh-manage session-backup restore --from latest --session <id>   # recuperar una sesion
dsh-manage session-backup repair --session <id> --mark-ignorable --yes  # sin reinstalar el plugin
dsh-manage session-backup prune --keep 10 --yes                  # limpiar snapshots viejos
```

`restore` y `repair` son las únicas dos operaciones de todo `session-backup`
que escriben bajo `sessions/`. Ambas exigen `dsh.service` detenido (el writer
mantiene un descriptor en modo append; escribir por debajo pierde la
restauración en silencio) y hacen un backup del estado actual antes de tocar
nada — el rollback siempre está disponible con otro `restore`.

`repair --mark-ignorable` es **lossy**: los eventos marcados dejan de
interpretarse (la sesión carga, pero lo que ese plugin mostraba no aparece).
Es la alternativa a reinstalar el plugin, no un reemplazo de tenerlo.

`plugins-remove` reemplaza a un `pnpm remove` manual cuando el paquete puede
tener eventos de sesión: corre el gate, hace backup si hace falta, y pide
confirmación antes de tocar nada. Para paquetes sin ese riesgo, sigue
funcionando `dsh plugin --profile <p> remove <paquete>` directo.
````

- [ ] **Step 4: Verificación final completa**

Run: `cd /opt/dsh-manage && make check && make bats`
Expected: shellcheck limpio, todos los tests verdes.

- [ ] **Step 5: Commit**

```bash
git add dsh-manage.sh CHANGELOG.md README.md tests/session-backup.bats
git commit -m "docs(session-backup): documentar restore/prune/repair/plugins-remove + bump a 1.3.0"
```

---

## Self-Review

**1. Cobertura del spec (Fases 3, 4, 5 + enmiendas §7.2, §7.3)**

| Sección del spec | Dónde se resuelve |
|---|---|
| §1 `restore` (flags `--from/--session/--force/--to-new-id`) | Task 1 |
| §1 `prune` (flags `--keep/--older-than/--yes`) | Task 2 |
| §1 `repair` (flags `--session/--mark-ignorable/--types/--yes`) | Task 6 |
| §4.2 gate compartido | Task 3 |
| §4.3 `plugins-remove` (backup automático, confirmación, restart) | Task 4 |
| §4.4 `plugins-install` post-check | Task 5 |
| §5.1 regla 4 (backup implícito) | Tasks 1 y 6 |
| §5.1 regla 5 (DSH detenido, sin override) | Tasks 1 y 6, `require_dsh_stopped()` |
| §5.5 reglas de `repair` (copiar byte a byte, `seq`/`time` intactos) | Task 6, `repair_events()` |
| §7.2 invalidación de `session_projcache.json` | Task 1, `invalidate_projcache_entry()`, usada también en Task 6 |
| §7.3 gate de `repair` superado | Ya ejecutado antes de este plan; Task 6 lo reproduce como parte del flujo real |
| §7.4 decisiones de alcance (plan único, restart mitigado, ronda de crítica) | Este plan entero |
| §5.6 códigos de salida (2, 3, 4, 5) | `session_backup_guard` usa 0/2/3; `plugins_remove` usa el rc del guard |

**Deliberadamente fuera de alcance** (no en el spec original tampoco): `--json`, `--quiet`, `--dry-run`, `--workspace`/`--session` en `scan` más allá de lo ya implementado en Fase 1+2, `--include-live` con lectura estable de logs vivos (documentado como diferencia deliberada respecto al `readStableFile` real del harness — timeout acotado en vez de loop infinito).

**2. Placeholders**: ninguno — cada paso tiene código o comando exacto. Los tests que dependen de bind de socket (Task 1 y 6, chequeo de "DSH corriendo") documentan explícitamente el fallback a `skip` si el sandbox de CI no permite el bind, sin dejarlo como instrucción vaga.

**3. Consistencia de tipos**: `invalidate_projcache_entry()` se define en Task 1 y se reutiliza en Task 6. `require_dsh_stopped()` se define en Task 1 y se reutiliza en Task 6. `restart_dsh()` se extrae en Task 4 y la usa tanto `plugins_install()` (ya existente, modificada) como `plugins_remove()` (nueva). `session_backup_guard()` se define en Task 3 y la consumen Task 4 (`plugins_remove`) y Task 5 (post-check, indirectamente vía `session_backup_scan`). El contrato `sessions[].{workspace,directory,artifact,id,...}` de `MANIFEST.json` (ya fijado en Fase 1+2) se reutiliza sin cambios en `cmd_restore_plan`.
