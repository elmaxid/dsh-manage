# Session Backup (Fases 3-5) Implementation Plan — v2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Completar `dsh-manage session-backup` con `restore`, `prune` y `repair`, y cerrar la causa raíz del incidente original integrando un gate de resguardo en `plugins-install`/`plugins-remove` (nuevo).

**Architecture:** Extiende el `dsh-manage.sh` y `plugins/session-scan.py` que ya existen (Fase 1+2, mergeada como v1.2.0). `restore`/`repair` son las primeras funciones de todo el feature que escriben bajo `$DSH_HOME/sessions/`.

**Tech Stack:** bash (`set -euo pipefail`), python3 + zstd/sha256sum/flock, bats-core.

**Spec:** `docs/SESSION-BACKUP-DESIGN.md` (§1, §4, §5, §7 — fases 3, 4 y 5; enmiendas §7.2, §7.3, §7.4)

---

## Por qué esta es la v2 (leer antes de implementar)

La v1 de este plan fue sometida a revisión (2 críticos formales + árbitro) y **se refutó**. El árbitro encontró 5 hallazgos que ningún crítico había visto, uno con **pérdida de datos real**, todos verificados ejecutando código. Durante la escritura final de esta v2 se detectaron y corrigieron **dos hallazgos adicionales** de la misma clase (rutas de éxito bien pensadas, rutas de error degradando a pérdida silenciosa):

1. **`prune` podía borrar el único backup de una sesión `broken`**. La causa: la variable de protección era global al snapshot en vez de evaluarse por sesión individual. **Corregido** en Task 2: protección evaluada sesión por sesión, procesando de más viejo a más nuevo.
2. **`restore` no funcionaba en su caso de uso principal** (recuperación total con `sessions/` vacío): el backup implícito previo trataba el código 2 de `create` ("nada que respaldar") como un fallo duro. **Corregido**: acepta 0 o 2 como "seguir".
3. **`make check` ya fallaba en `main` antes de tocar este plan** (2 `SC2181` preexistentes). **Corregido** en Task 2.
4. **El bug de `set -e` perdiendo un código de retorno aparecía en dos sitios distintos**. **Corregido** en ambos con `rc=0; cmd || rc=$?`.
5. `repair_events()` marcaba el header (`type:"session"`) con `ignorable:true`. **Corregido**: el header se excluye explícitamente.
6. **`restore --from latest` podía restaurar el snapshot equivocado**: `latest` es un symlink que el propio backup implícito de `restore` re-apunta antes de que la copia real ocurra. Reproducido en sandbox. **Corregido**: `readlink -f` se aplica una sola vez, antes de tocar nada.
7. **`repair` podía destruir en silencio la cola de un log con una escritura interrumpida**: `repair_events()` descomprimía con `zstd -dc` sin mirar el código de retorno — si el frame estaba truncado (`rc=1`), tomaba solo los datos parciales recuperados, los recomprimía, y publicaba eso in-place como si fuera el archivo completo. Reproducido con un artefacto truncado al 70%: `zstd -dc` da `rc=1` y 0 líneas recuperables, y sin el chequeo el comando habría "reparado" y publicado un archivo vacío reportando éxito. **Corregido**: `repair` ahora aborta si el artefacto está torn, en vez de proceder.
8. **Los temporales de `repair` (`.repair-plain`, `.repair-tmp`) se creaban dentro de `$DSH_HOME/sessions/`**, violando el invariante de que nada temporal vive ahí — alcanza con que estén en el mismo filesystem (confirmado: mismo device id) para que `mv -T` siga siendo atómico. **Corregido**: se mueven a un scratch bajo `$DSH_BACKUP_ROOT`.
9. **`plugins_remove()` reiniciaba `dsh.service` incondicionalmente**, sin importar qué profile se tocó. Confirmado leyendo el unit real generado por `service_install()`: `dsh.service` sirve siempre y únicamente el profile `web` (`PROFILE_DIR` fijo en el script del servicio) — no existe "un `dsh.service` por profile". Remover un paquete de un profile de prueba (ej. `repro`) no tiene ninguna razón para reiniciar producción. **Corregido**: el restart solo corre cuando `$profile = "web"`.
10. **El label automático `preremove-<pkg>` podía quedar con un guión colgante** (`preremove-dsh-swarm-panel-`): `echo "$pkg" | tr -c ...` convierte el `\n` final de `echo` en un `-`. Reproducido. **Corregido**: `printf '%s'` en vez de `echo`.

Todo el código de los fixes más críticos de esta v2 fue validado ejecutándolo en sandboxes descartables antes de escribirse en este documento.

---

## Global Constraints

- Bash con `set -euo pipefail`; shellcheck limpio (`make check`) — **incluye sanear los 2 `SC2181` preexistentes**, ver Task 2.
- Comentarios y salida al usuario en español.
- **`restore` y `repair` son las únicas funciones que escriben bajo `$DSH_HOME/sessions/`.** Todo lo demás sigue read-only ahí. **Ningún archivo temporal se crea bajo `sessions/`** — los temporales de `repair` viven en `$DSH_BACKUP_ROOT/.repair-scratch/` (mismo filesystem, `mv -T` sigue siendo atómico).
- **`restore` y `repair` exigen DSH detenido, verificado dos veces**: al inicio y justo antes del `mv -T` final.
- **`restore` y `repair` hacen `create` implícito** antes de escribir. Código de retorno: **0 o 2 → seguir**; cualquier otro → abortar.
- **`--from <nombre>` se resuelve a una ruta absoluta con `readlink -f` ANTES de cualquier operación que pueda cambiar a qué apunta `latest`** (en particular, antes del backup implícito).
- **`repair` aborta si el artefacto de origen está torn** (cola rota — `zstd -dc` con `returncode != 0`). Una cola rota "sigue siendo restaurable" para *lectura* (spec §5.2), pero `repair` *reescribe* el artefacto, y publicar solo el fragmento recuperado como si fuera el log completo sería pérdida de datos silenciosa. `repair_events()` debe propagar ese estado, no ignorarlo.
- **Escritura atómica**: temporal en el mismo filesystem + `mv -T` al nombre final.
- **`repair` copia byte a byte lo que no toca, y el header (`type:"session"`) nunca se toca**, sea cual sea el baseline.
- **`--to-new-id` reescribe el `id` dentro del header JSON**, no solo el nombre del directorio — copiar el artefacto sin tocar el header produce una sesión que el harness rechaza al abrir o que colisiona en el listado.
- **`--force` en `restore`**: si el destino existe y difiere del snapshot, **abortar sin `--force`**.
- **Todo `cmd; rc=$?` bajo `set -e` es un bug** — usar siempre `rc=0; cmd || rc=$?`.
- **`session_backup_guard()` es de solo lectura**: nunca escribe, nunca crea backups. Devuelve 0/1/3. No existe el código 2.
- **`invalidate_projcache_entry()` usa igualdad exacta de `id`**, nunca `endswith`/prefijo.
- **Ningún fallback de búsqueda de sesión usa `grep` sobre artefactos `.zstd`** — son binarios comprimidos.
- **La validación previa a publicar un `repair` compara líneas y header contra el original**, no solo `zstd -t` (que valida el contenedor, no el contenido — verificado: un `.zstd` con basura adentro pasa `zstd -t` con rc=0).
- Nombres de función y contrato JSON existentes (no romper): `dsh_session_lib_path()`, `session_backup_preflight()`, `DSH_BACKUP_ROOT`, `session_backup_verify_dir()`, `session_backup_create()`, `session_backup_scan()` (acepta **solo** `--profile <val>` y `--fail-on-risk`, nunca un posicional).
- `DSH_MANAGE_VERSION` sube a `1.4.0` en la última tarea. **Nota**: mientras este plan estaba en revisión, `main` recibió un commit externo no relacionado (`3a73389`, actualización del stack de plugins homologado) que ya bumpeó a `1.3.0` por su cuenta — la próxima versión libre para este feature es `1.4.0`, no `1.3.0`. El test existente que afirma la versión de `dshManageVersion` en el manifest se actualiza en el mismo commit al valor real vigente al momento de implementar (verificar `grep DSH_MANAGE_VERSION dsh-manage.sh` antes de escribir el bump, por si hubo otro cambio externo entretanto).
- `read_stable_bytes()` / `--include-live`: **fuera de alcance de Fases 3-5**.

---

## File Structure

| Archivo | Responsabilidad |
|---|---|
| `plugins/session-scan.py` (modificar) | `repair_events()` (header excluido, aborta si torn), `find_session` (sin grep sobre binarios), `restore-plan`/`restore-new-id`. |
| `dsh-manage.sh` (modificar) | `session_backup_restore()` (symlink resuelto antes del backup implícito), `session_backup_prune()` (protección por-sid), `session_backup_repair()` (temporales fuera de `sessions/`), `session_backup_guard()`, `plugins_remove()`, hook completo en `plugins_install()`, `restart_dsh()`, `invalidate_projcache_entry()`. |
| `tests/session-backup.bats` (modificar) | Tests de las 7 tareas; el `SC2181` preexistente se corrige acá también. |
| `README.md`, `CHANGELOG.md`, `dsh-manage.sh` (modificar) | Documentación y bump a la próxima versión libre (`1.4.0` al momento de escribir este plan — confirmar contra `main` antes de implementar Task 7). |

---

### Task 1: `restore`

**Files:**
- Modify: `plugins/session-scan.py`
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_preflight()`, `dsh_session_lib_path()`, `DSH_BACKUP_ROOT`, `session_backup_verify_dir()`, `session_backup_create()` (Fase 1+2).
- Produces: `require_dsh_stopped()`, `session_backup_restore()`, `invalidate_projcache_entry()` (bash); CLI `session-scan.py restore-plan`/`restore-new-id` (Python).

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "restore exige DSH detenido" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r1--" "session-r1" "session-r1" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r1
  python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 39217))
s.listen(1)
time.sleep(2)
" &
  listener_pid=$!
  sleep 0.3
  run env DSH_PORT=39217 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest
  kill "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"corriendo"* ]] || [[ "$output" == *"detene"* ]]
}

@test "restore --from latest restaura el snapshot que existia al invocar, no el backup implicito posterior" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r0--" "session-r0" "session-r0" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label snap-bueno
  printf 'ESTADO-ROTO' > "$DSH_HOME/sessions/--ws-r0--/session-r0/session.jsonl.zstd"
  run env DSH_PORT=39227 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --force
  [ "$status" -eq 0 ]
  run zstd -t "$DSH_HOME/sessions/--ws-r0--/session-r0/session.jsonl.zstd"
  [ "$status" -eq 0 ]
  content="$(zstd -dc "$DSH_HOME/sessions/--ws-r0--/session-r0/session.jsonl.zstd")"
  [[ "$content" != *"ESTADO-ROTO"* ]]
  [[ "$content" == *'"type":"tipo/1"'* ]]
}

@test "restore sin DSH corriendo restaura una sesion desde el snapshot" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r2--" "session-r2" "session-r2" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r2
  printf 'CORRUPTO' > "$DSH_HOME/sessions/--ws-r2--/session-r2/session.jsonl.zstd"
  run env DSH_PORT=39218 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --force
  [ "$status" -eq 0 ]
  run zstd -t "$DSH_HOME/sessions/--ws-r2--/session-r2/session.jsonl.zstd"
  [ "$status" -eq 0 ]
}

@test "restore sin --force no pisa un destino que difiere" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r3--" "session-r3" "session-r3" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r3
  printf 'CORRUPTO' > "$DSH_HOME/sessions/--ws-r3--/session-r3/session.jsonl.zstd"
  run env DSH_PORT=39222 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --session session-r3
  [ "$status" -ne 0 ]
  [[ "$output" == *"--force"* ]]
  [ "$(cat "$DSH_HOME/sessions/--ws-r3--/session-r3/session.jsonl.zstd")" = "CORRUPTO" ]
}

@test "restore --session limita a una sola sesion" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r4--" "session-r4a" "session-r4a" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  fake_session "$DSH_HOME/sessions" "--ws-r4--" "session-r4b" "session-r4b" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r4
  printf 'CORRUPTO-A' > "$DSH_HOME/sessions/--ws-r4--/session-r4a/session.jsonl.zstd"
  printf 'CORRUPTO-B' > "$DSH_HOME/sessions/--ws-r4--/session-r4b/session.jsonl.zstd"
  run env DSH_PORT=39219 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --session session-r4a --force
  [ "$status" -eq 0 ]
  run zstd -t "$DSH_HOME/sessions/--ws-r4--/session-r4a/session.jsonl.zstd"
  [ "$status" -eq 0 ]
  [ "$(cat "$DSH_HOME/sessions/--ws-r4--/session-r4b/session.jsonl.zstd")" = "CORRUPTO-B" ]
}

@test "restore --to-new-id reescribe el id del header, no solo el directorio" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r5--" "session-r5" "session-r5" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r5
  run env DSH_PORT=39220 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --session session-r5 --to-new-id
  [ "$status" -eq 0 ]
  new_dir="$(find "$DSH_HOME/sessions/--ws-r5--" -mindepth 1 -maxdepth 1 -type d ! -name session-r5)"
  [ -n "$new_dir" ]
  new_id="$(zstd -dc "$new_dir/session.jsonl.zstd" | head -1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  [ "$new_id" != "session-r5" ]
  [[ "$new_id" == session-* ]]
}

@test "restore con sessions vacio no aborta por 'nada que respaldar' del backup implicito" {
  install_fake_harness 48
  mkdir -p "$DSH_BACKUP_ROOT"
  fake_session "$DSH_HOME/sessions" "--ws-r6--" "session-r6" "session-r6" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label snap-con-datos
  rm -rf "${DSH_HOME:?}/sessions"
  mkdir -p "$DSH_HOME/sessions"
  run env DSH_PORT=39223 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --force
  [ "$status" -eq 0 ]
  [ -f "$DSH_HOME/sessions/--ws-r6--/session-r6/session.jsonl.zstd" ]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `restore` no es un subcomando válido.

- [ ] **Step 3: Agregar `restore-plan` y la reescritura de header al helper Python**

Agregar a `plugins/session-scan.py`, antes de `main()`:

```python
def cmd_restore_plan(args):
    """Calcula que copiar para un restore, sin ejecutar nada."""
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


def rewrite_header_id(src_path, new_id):
    """Devuelve el contenido con el id del header (primera linea) reescrito.
    Las demas lineas se preservan byte a byte -- copiar el artefacto sin
    tocar el header produce una sesion que el harness rechaza al abrir
    (assertStoredIdentity compara la ruta con meta.id/meta.cwd del header)."""
    if src_path.endswith(".zstd"):
        raw = subprocess.run(["zstd", "-dc", src_path], capture_output=True).stdout.decode("utf-8", errors="replace")
    else:
        with open(src_path, encoding="utf-8", errors="replace") as f:
            raw = f.read()
    lines = raw.splitlines()
    if not lines:
        raise SystemExit(f"artefacto vacio: {src_path}")
    header = json.loads(lines[0])
    header["id"] = new_id
    lines[0] = json.dumps(header, ensure_ascii=False)
    return "\n".join(lines) + "\n"


def cmd_restore_new_id(args):
    content = rewrite_header_id(args.artifact, args.new_id)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(content)
```

y su registro en `main()`:

```python
    p = sub.add_parser("restore-plan", help="calcula que copiar para un restore (uso interno)")
    p.add_argument("--snap-dir", required=True)
    p.add_argument("--sessions", required=True)
    p.add_argument("--session", default=None, help="limitar a una sesion (id o directory)")
    p.set_defaults(func=cmd_restore_plan)

    p = sub.add_parser("restore-new-id", help="reescribe el id del header (uso interno)")
    p.add_argument("--artifact", required=True)
    p.add_argument("--new-id", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_restore_new_id)
```

- [ ] **Step 4: Agregar `restore` en bash**

En `dsh-manage.sh`, agregar después de `session_backup_verify()`:

```bash
# Chequeo obligatorio antes de restore/repair. Se llama DOS VECES: al inicio
# (falla rapido) y de nuevo justo antes del mv -T final.
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

# Invalida la entrada de una sesion en session_projcache.json. Igualdad
# EXACTA de id -- este host tiene ids con y sin el prefijo "session-"
# coexistiendo, y un match por endswith/prefijo puede borrar de mas.
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
if sid not in sessions:
    sys.exit(0)
del sessions[sid]
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

# restore: copia sesiones desde un snapshot de vuelta a sessions/.
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
  [ -e "$snap" ] || { echo "snapshot no encontrado: $snap" >&2; return 1; }
  # CRITICO: resolver el symlink a una ruta ABSOLUTA REAL ahora, antes de
  # tocar nada. "latest" es un symlink que session_backup_create() (el
  # backup implicito de mas abajo) va a re-apuntar al terminar -- si $snap
  # siguiera siendo la ruta "via latest" en vez de la ruta resuelta, el
  # resto de esta funcion leeria el backup implicito recien creado en vez
  # del snapshot original.
  snap="$(readlink -f "$snap")"
  [ -d "$snap" ] || { echo "snapshot no encontrado tras resolver: $snap" >&2; return 1; }
  session_backup_verify_dir "$snap" || { echo "snapshot invalido, abortando restore" >&2; return 1; }

  echo "creando backup del estado actual antes de restaurar..."
  local backup_rc=0
  session_backup_create --label "pre-restore-$(date -u +%Y%m%dT%H%M%SZ)" || backup_rc=$?
  if [ "$backup_rc" -ne 0 ] && [ "$backup_rc" -ne 2 ]; then
    echo "fallo el backup previo (rc=$backup_rc); abortando restore sin tocar nada" >&2
    return 1
  fi

  umask 077
  local sessions_dir="$DSH_HOME/sessions"
  local plan_args=("$DSH_MANAGE_DIR/plugins/session-scan.py" restore-plan --snap-dir "$snap" --sessions "$sessions_dir")
  [ -n "$session" ] && plan_args+=(--session "$session")
  local plan
  plan="$(python3 "${plan_args[@]}")" || return 1

  local count=0
  while IFS=$'\t' read -r src dst directory sid; do
    [ -n "$src" ] || continue

    if [ "$to_new_id" -eq 1 ]; then
      local new_dir new_id
      new_id="session-$(python3 -c 'import uuid; print(uuid.uuid4())')"
      new_dir="$(cd "$(dirname "$dst")/.." && pwd)/$new_id"
      mkdir -p "$new_dir"
      local rewritten="$new_dir/$(basename "$dst")"
      local tmp_plain="${rewritten}.plain"
      python3 "$DSH_MANAGE_DIR/plugins/session-scan.py" restore-new-id \
        --artifact "$src" --new-id "$new_id" --out "$tmp_plain" || { rm -f "$tmp_plain"; return 1; }
      if [[ "$rewritten" == *.zstd ]]; then
        zstd -q -f -o "$rewritten" "$tmp_plain" || { rm -f "$tmp_plain" "$rewritten"; return 1; }
        rm -f "$tmp_plain"
      else
        mv -T "$tmp_plain" "$rewritten"
      fi
      count=$((count + 1))
      continue
    fi

    if [ -e "$dst" ]; then
      local cur_sum snap_sum
      cur_sum="$(sha256sum "$dst" | cut -d' ' -f1)"
      snap_sum="$(sha256sum "$src" | cut -d' ' -f1)"
      if [ "$cur_sum" = "$snap_sum" ]; then
        continue
      fi
      if [ "$force" -ne 1 ]; then
        echo "'$dst' existe y difiere del snapshot; use --force para pisarlo" >&2
        return 1
      fi
    fi

    require_dsh_stopped || { echo "dsh arranco durante el restore; abortando antes de escribir $dst" >&2; return 1; }

    mkdir -p "$(dirname "$dst")"
    local tmp="${dst}.restore-tmp"
    cp "$src" "$tmp"
    mv -T "$tmp" "$dst"
    invalidate_projcache_entry "$sid" || true
    count=$((count + 1))
  done < <(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
for r in d['restores']:
    print(f\"{r['src']}\t{r['dst']}\t{r['directory']}\t{r['id']}\")
" "$plan")

  echo "restore completo: $count archivo(s) restaurado(s) desde $snap"
}
```

Ampliar el despachador `session_backup()`:

```bash
    restore)  session_backup_restore "$@" ;;
```
y su línea de uso a `{scan|create|list|verify|restore}`.

- [ ] **Step 5: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS. `make check` no quedará limpio todavía (Task 2 sanea los preexistentes). Confirmar sin warnings nuevos en `dsh-manage.sh`.

- [ ] **Step 6: Verificar contra el host real (con cuidado — toca sesiones reales)**

```bash
cd /opt/dsh-manage
./dsh-manage.sh session-backup create --label antes-de-probar-restore
snap_fuente="$(basename "$(readlink -f "$HOME/.dsh/session-backups/latest")")"
systemctl stop dsh.service
./dsh-manage.sh session-backup restore --from "$snap_fuente" --session <un-id-de-sesion-de-prueba> --force
systemctl start dsh.service
./dsh-manage.sh session-backup verify --from "$snap_fuente"
```
Expected: `restore completo: N archivo(s) restaurado(s)`.

- [ ] **Step 7: Commit**

```bash
git add plugins/session-scan.py dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): subcomando restore, con resolucion de symlink previa al backup implicito"
```

---

### Task 2: `prune` (protección por-sesión, y saneo del shellcheck heredado)

**Files:**
- Modify: `dsh-manage.sh`
- Modify: `tests/session-backup.bats`
- Test: `tests/session-backup.bats`

- [ ] **Step 1: Sanear los `SC2181` preexistentes**

`make check` en `main` ya falla hoy por 2 warnings en `tests/session-backup.bats` (patrón `[ "$?" -eq 0 ]`). Buscar con `grep -n '\$?'` y refactorizar al patrón `run comando; [ "$status" -eq 0 ]`. Confirmar con `shellcheck tests/session-backup.bats`.

- [ ] **Step 2: Escribir los tests que fallan**

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
  count="$(find "$DSH_BACKUP_ROOT" -maxdepth 1 -type d ! -name '*.partial' ! -path "$DSH_BACKUP_ROOT" | wc -l)"
  [ "$count" -eq 2 ]
}

@test "prune --keep conserva los N mas recientes" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-p2--" "session-p2" "session-p2" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label viejo
  sleep 1.1
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label nuevo
  viejo_dir="$(ls -d "$DSH_BACKUP_ROOT"/*-viejo)"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup prune --keep 1 --yes
  [ "$status" -eq 0 ]
  [ ! -d "$viejo_dir" ]
  ls -d "$DSH_BACKUP_ROOT"/*-nuevo
}

@test "prune nunca borra la unica copia de una sesion broken, incluso compartiendo snapshot con otra cubierta" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-p3--" "session-S1" "session-S1" \
    '{"type":"foo/x","seq":1,"time":1,"data":{}}'
  fake_session "$DSH_HOME/sessions" "--ws-p3--" "session-S2" "session-S2" \
    '{"type":"foo/x","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label snap-A
  a_dir="$(ls -d "$DSH_BACKUP_ROOT"/*-snap-A)"
  sleep 1.1
  rm -rf "$DSH_HOME/sessions/--ws-p3--/session-S2"
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label snap-B
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup prune --keep 0 --yes
  [ "$status" -eq 0 ]
  [ -d "$a_dir" ]
}

@test "prune borra sin protegerse de mas cuando la sesion SI tiene otra copia" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-p4--" "session-S1" "session-S1" \
    '{"type":"foo/x","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label snap-A
  a_dir="$(ls -d "$DSH_BACKUP_ROOT"/*-snap-A)"
  sleep 1.1
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label snap-B
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup prune --keep 1 --yes
  [ "$status" -eq 0 ]
  [ ! -d "$a_dir" ]
}

@test "prune --older-than borra por edad" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-p5--" "session-p5" "session-p5" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label reciente
  snap="$(ls -d "$DSH_BACKUP_ROOT"/*-reciente)"
  viejo="$DSH_BACKUP_ROOT/20200101T000000Z-viejo-de-verdad"
  cp -r "$snap" "$viejo"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup prune --older-than 30 --yes
  [ "$status" -eq 0 ]
  [ ! -d "$viejo" ]
  [ -d "$snap" ]
}
```

- [ ] **Step 3: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `prune` no es un subcomando válido.

- [ ] **Step 4: Escribir la implementación**

Agregar a `dsh-manage.sh`, después de `session_backup_restore()`:

```bash
# prune: borra snapshots viejos por retencion. Proteccion POR SESION, no por
# snapshot: procesa de mas viejo a mas nuevo, considerando "sobrevivientes"
# a todo lo que no fue decidido a borrar TODAVIA en esta misma pasada.
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
    echo "prune requiere --yes para borrar de verdad" >&2
    return 1
  fi

  [ -d "$DSH_BACKUP_ROOT" ] || { echo "no hay snapshots ($DSH_BACKUP_ROOT no existe)"; return 0; }

  local candidates=() dir
  for dir in "$DSH_BACKUP_ROOT"/*/; do
    [ -d "$dir" ] || continue
    case "${dir%/}" in *.partial|*/latest) continue ;; esac
    [ -f "${dir}MANIFEST.json" ] || continue
    candidates+=("${dir%/}")
  done
  mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort)

  local total=${#candidates[@]}
  local to_delete=()
  if [ -n "$older_than" ]; then
    local cutoff
    cutoff="$(date -u -d "-${older_than} days" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -v-"${older_than}"d +%Y%m%dT%H%M%SZ)"
    for dir in "${candidates[@]}"; do
      local name; name="$(basename "$dir")"
      [[ "$name" < "$cutoff" ]] && to_delete+=("$dir")
    done
  else
    if [ "$total" -gt "$keep" ]; then
      local n_delete=$((total - keep)) i
      for ((i = 0; i < n_delete; i++)); do
        to_delete+=("${candidates[$i]}")
      done
    fi
  fi

  local deleted=0 protected=0 final_delete=()
  for dir in "${to_delete[@]}"; do
    local cur_survivors=() c
    for c in "${candidates[@]}"; do
      [ "$c" = "$dir" ] && continue
      local already_deleted=0 fd
      for fd in "${final_delete[@]}"; do [ "$fd" = "$c" ] && already_deleted=1; done
      [ "$already_deleted" -eq 1 ] && continue
      cur_survivors+=("$c")
    done

    local can_delete=1
    local broken_sids
    broken_sids="$(python3 -c "
import json
try:
    m = json.load(open('$dir/MANIFEST.json'))
except Exception:
    raise SystemExit
print(' '.join(s['id'] for s in m.get('sessions', []) if s.get('risk') == 'broken'))
" 2>/dev/null)"
    if [ -n "$broken_sids" ]; then
      local sid
      for sid in $broken_sids; do
        local covered=0 other
        for other in "${cur_survivors[@]}"; do
          if python3 -c "
import json, sys
m = json.load(open('$other/MANIFEST.json'))
sys.exit(0 if any(s['id'] == '$sid' for s in m['sessions']) else 1)
" 2>/dev/null; then
            covered=1
          fi
        done
        if [ "$covered" -eq 0 ]; then
          can_delete=0
        fi
      done
    fi

    if [ "$can_delete" -eq 1 ]; then
      final_delete+=("$dir")
      rm -rf -- "$dir"
      deleted=$((deleted + 1))
    else
      protected=$((protected + 1))
      echo "protegido (unica copia de al menos una sesion broken): $(basename "$dir")"
    fi
  done

  echo "prune: $deleted snapshot(s) borrado(s), $protected protegido(s) por ser la unica copia de una sesion broken"
}
```

Ampliar el despachador:

```bash
    prune)    session_backup_prune "$@" ;;
```
y su línea de uso a `{scan|create|list|verify|restore|prune}`.

- [ ] **Step 5: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + `make check` limpio de verdad.

- [ ] **Step 6: Verificar contra el host real**

```bash
cd /opt/dsh-manage
before="$(./dsh-manage.sh session-backup list)"
./dsh-manage.sh session-backup prune --keep 5 --yes
after="$(./dsh-manage.sh session-backup list)"
diff <(echo "$before") <(echo "$after") || true
```
Expected: conserva los 5 más recientes; cualquier `broken` sin otra copia queda listado como "protegido".

- [ ] **Step 7: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): subcomando prune, con proteccion por-sesion (no por-snapshot)"
```

---

### Task 3: `session_backup_guard` (gate compartido, contrato read-only)

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_scan()` (con `--profile`, nunca posicional), `scan_plugin_vocabulary()` vía `session-scan.py`.
- Produces: `session_backup_guard()`.

**Contrato**: solo lectura. `0` sin impacto; `1` error duro (llamador aborta); `3` impacto detectado (el llamador decide backup+confirmación). No existe el código `2`.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "session_backup_guard detecta cuando un paquete a remover deja sesiones broken" {
  install_fake_harness 48
  nm="$BATS_TEST_TMPDIR/nm-guard"
  fake_plugin "$nm" "plugin-guard-test" "guard/evento"
  fake_session "$DSH_HOME/sessions" "--ws-g1--" "session-g1" "session-g1" \
    '{"type":"guard/evento","seq":1,"time":1,"data":{}}'
  source "$BATS_TEST_DIRNAME/../dsh-manage.sh" --lib
  run session_backup_guard remove "$nm/plugin-guard-test" web
  [ "$status" -eq 3 ]
  [[ "$output" == *"session-g1"* ]] || [[ "$output" == *"1"* ]]
}

@test "session_backup_guard no bloquea cuando no hay sesiones afectadas" {
  install_fake_harness 48
  nm="$BATS_TEST_TMPDIR/nm-guard2"
  fake_plugin "$nm" "plugin-sin-uso" "sinuso/evento"
  source "$BATS_TEST_DIRNAME/../dsh-manage.sh" --lib
  run session_backup_guard remove "$nm/plugin-sin-uso" web
  [ "$status" -eq 0 ]
}

@test "session_backup_guard nunca escribe nada (es read-only)" {
  install_fake_harness 48
  nm="$BATS_TEST_TMPDIR/nm-guard3"
  fake_plugin "$nm" "plugin-guard-ro" "guardro/evento"
  fake_session "$DSH_HOME/sessions" "--ws-g3--" "session-g3" "session-g3" \
    '{"type":"guardro/evento","seq":1,"time":1,"data":{}}'
  before="$(find "$DSH_HOME/sessions" "$DSH_BACKUP_ROOT" -type f 2>/dev/null | sort)"
  source "$BATS_TEST_DIRNAME/../dsh-manage.sh" --lib
  run session_backup_guard remove "$nm/plugin-guard-ro" web
  [ "$status" -eq 3 ]
  after="$(find "$DSH_HOME/sessions" "$DSH_BACKUP_ROOT" -type f 2>/dev/null | sort)"
  [ "$before" = "$after" ]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `session_backup_guard` no existe.

- [ ] **Step 3: Escribir la implementación**

Agregar a `dsh-manage.sh`, después de `session_backup_prune()`:

```bash
# Gate compartido, READ-ONLY. Contrato: 0=sin impacto, 1=error duro,
# 3=impacto detectado (el LLAMADOR decide backup+confirmacion).
session_backup_guard() {
  local accion="$1" pkg_dir="$2" profile="$3"
  session_backup_preflight || return 1

  local sessions_dir="$DSH_HOME/sessions"
  [ -d "$sessions_dir" ] || return 0

  local pkg_types
  pkg_types="$(python3 - "$pkg_dir" <<'PY'
import sys, os, re
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
)" || return 1

  if [ -z "$pkg_types" ]; then
    return 0
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
hits = []
for s in scan['sessions']:
    types_here = {u['type'] for u in s.get('unknownTypes', [])}
    if types_here & pkg_types:
        hits.append(s['id'])
print(len(hits))
for h in hits:
    print(h)
" "$scan_json" "$pkg_types")"

  local n_affected
  n_affected="$(echo "$affected" | head -1)"
  if [ "$n_affected" -eq 0 ] 2>/dev/null; then
    return 0
  fi

  echo "⚠ esta operacion ($accion) afecta a $n_affected sesion(es):"
  echo "$affected" | tail -n +2 | sed 's/^/    /'
  return 3
}
```

- [ ] **Step 4: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 5: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): gate compartido session_backup_guard (read-only, contrato 0/1/3)"
```

---

### Task 4: `plugins_remove()` con restart mitigado

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_guard()` (Task 3), `session_backup_create()`, `port_pid()`/`wait_for_port()`, `dsh_service_manages_this_home()`.
- Produces: `restart_dsh()`, `plugins_remove()`, dispatcher `plugins-remove`.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "plugins_remove sin --yes y sin TTY aborta sin tocar nada" {
  install_fake_harness 48
  mkdir -p "$DSH_HOME/profiles/web/node_modules/paquete-inexistente"
  cat > "$DSH_HOME/profiles/web/package.json" <<'EOF'
{"name":"web","dependencies":{"paquete-inexistente":"1.0.0"}}
EOF
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" plugins-remove paquete-inexistente web < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* ]] || [[ "$output" == *"TTY"* ]]
}

@test "plugins_remove con paquete no declarado en package.json falla limpio" {
  install_fake_harness 48
  mkdir -p "$DSH_HOME/profiles/web"
  echo '{"name":"web","dependencies":{}}' > "$DSH_HOME/profiles/web/package.json"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" plugins-remove paquete-que-no-existe web --yes
  [ "$status" -ne 0 ]
}

@test "guard_rc se captura correctamente bajo set -e (no se pierde con impacto detectado)" {
  install_fake_harness 48
  nm="$DSH_HOME/profiles/web/node_modules"
  mkdir -p "$nm/plugin-con-impacto/lib"
  cat > "$nm/plugin-con-impacto/package.json" <<'EOF'
{"name":"plugin-con-impacto","version":"1.0.0"}
EOF
  cat > "$nm/plugin-con-impacto/lib/index.js" <<'EOF'
import { KNOWN_SESSION_EVENT_TYPES } from "@deepseek-ai/dsh-session";
export function emit(s) { s.append("impacto/evento", {}); }
EOF
  cat > "$DSH_HOME/profiles/web/package.json" <<'EOF'
{"name":"web","dependencies":{"plugin-con-impacto":"1.0.0"}}
EOF
  fake_session "$DSH_HOME/sessions" "--ws-gr--" "session-gr" "session-gr" \
    '{"type":"impacto/evento","seq":1,"time":1,"data":{}}'
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" plugins-remove plugin-con-impacto web --yes
  [[ "$output" == *"backup automatico"* ]]
}

@test "plugins_remove no reinicia dsh.service al tocar un profile que no es web" {
  install_fake_harness 48
  mkdir -p "$DSH_HOME/profiles/repro/node_modules/paquete-en-repro"
  cat > "$DSH_HOME/profiles/repro/package.json" <<'EOF'
{"name":"repro","dependencies":{"paquete-en-repro":"1.0.0"}}
EOF
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" plugins-remove paquete-en-repro repro --yes
  [[ "$output" == *"no hace falta reiniciar dsh"* ]]
  [[ "$output" != *"reiniciando dsh"* ]]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `plugins-remove` no está en el dispatcher.

- [ ] **Step 3: Extraer `restart_dsh()` de `plugins_install()`**

En `dsh-manage.sh`, dentro de `plugins_install()`, reemplazar el bloque final de restart+verificación por `restart_dsh || return 1`, y agregar la función `restart_dsh()` justo antes de `plugins_install() {`:

```bash
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
    session_backup_guard remove "$pkg_dir" "$profile" || guard_rc=$?
  fi

  if [ "$guard_rc" -eq 1 ]; then
    echo "el gate de resguardo fallo con un error duro; abortando plugins-remove sin remover nada" >&2
    return 1
  fi

  if [ "$guard_rc" -eq 3 ]; then
    echo "creando backup automatico antes de continuar (trigger: plugins-remove)..."
    DSH_TRIGGER="plugins-remove" session_backup_create --only-at-risk \
      --label "preremove-$(printf '%s' "$pkg" | tr -c 'A-Za-z0-9._-' '-')" || {
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
    echo "sin --yes y sin TTY: abortando sin remover nada" >&2
    return 1
  fi

  echo "removiendo '$pkg' del profile '$profile'..."
  (cd "$profile_dir" && PATH="$DSH_NODE:$PATH" pnpm remove "$pkg") \
    || { echo "pnpm remove falló, ver arriba" >&2; return 1; }

  # dsh.service (generado por service_install) siempre sirve el profile
  # "web" (PROFILE_DIR esta fijo en el unit) -- no hay un dsh.service por
  # profile. Reiniciar produccion por tocar un profile que NO es el
  # servido (ej. "repro") seria un impacto no consentido en un server
  # compartido. Solo reiniciamos si el profile tocado es el productivo.
  if [ "$profile" = "web" ]; then
    restart_dsh || return 1
  else
    echo "profile '$profile' no es 'web' (el que sirve dsh.service) -- no hace falta reiniciar dsh"
  fi

  echo "verificando el impacto real tras el restart..."
  local post_rc=0
  session_backup_scan --profile "$profile" --fail-on-risk >/dev/null 2>&1 || post_rc=$?
  if [ "$post_rc" -eq 4 ]; then
    echo "⚠ hay sesiones 'broken' tras remover '$pkg'. Backup disponible con 'dsh-manage session-backup list'." >&2
  fi

  echo "listo: '$pkg' removido del profile '$profile'"
}
```

Agregar al dispatcher, después de `plugins-install)`:

```bash
  plugins-remove)   plugins_remove "${2:-}" "${3:-web}" "${@:4}" ;;
```
y actualizar la línea de uso.

- [ ] **Step 5: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 6: Verificar contra el host real — SOLO en un profile descartable**

```bash
cd /opt/dsh-manage
./dsh-manage.sh plugins-remove dsh-defend repro --yes 2>&1 | tail -20
(cd "$HOME/.dsh/profiles/repro" && PATH="$HOME/.local/dsh-node/node24/bin:$PATH" pnpm install)
```
Expected: `pnpm remove` sale limpio; el restart no debe afectar el `dsh.service` real si `repro` no es su `WorkingDirectory`.

- [ ] **Step 7: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): plugins_remove con gate de resguardo obligatorio"
```

---

### Task 5: Gate completo de `session_backup_guard` en `plugins_install()` (pre-install + post-check)

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_guard()` (Task 3).
- Produces: modificación de `plugins_install()` existente.

- [ ] **Step 1: Escribir el test que falla**

Agregar a `tests/session-backup.bats`:

```bash
@test "plugins_install crea backup pre-install cuando un paquete del manifest es event-writer con sesiones afectadas" {
  install_fake_harness 48
  mkdir -p "$DSH_HOME/profiles/web"
  fake_session "$DSH_HOME/sessions" "--ws-pi1--" "session-pi1" "session-pi1" \
    '{"type":"preinstall/evento","seq":1,"time":1,"data":{}}'
  nm_fake="$BATS_TEST_TMPDIR/tarball-plugin/lib"
  mkdir -p "$nm_fake"
  cat > "$BATS_TEST_TMPDIR/tarball-plugin/package.json" <<'EOF'
{"name":"plugin-preinstall-test","version":"1.0.0"}
EOF
  cat > "$nm_fake/index.js" <<'EOF'
import { KNOWN_SESSION_EVENT_TYPES } from "@deepseek-ai/dsh-session";
export function emit(s) { s.append("preinstall/evento", {}); }
EOF
  source "$BATS_TEST_DIRNAME/../dsh-manage.sh" --lib
  run session_backup_guard install "$BATS_TEST_TMPDIR/tarball-plugin" web
  [ "$status" -eq 3 ]
  [[ "$output" == *"session-pi1"* ]] || [[ "$output" == *"1"* ]]
}

@test "plugins_install post-check usa --profile correctamente (no posicional)" {
  install_fake_harness 48
  mkdir -p "$DSH_HOME/sessions"
  source "$BATS_TEST_DIRNAME/../dsh-manage.sh" --lib
  run session_backup_scan --profile web --fail-on-risk
  [ "$status" -eq 0 ]
  [[ "$output" != *"opcion desconocida"* ]]
}
```

- [ ] **Step 2: Correr los tests**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats -f "plugins_install"`
Expected: ambos pasan ya (dependen de Task 3, sirven de referencia para el Step 3).

- [ ] **Step 3: Agregar el gate pre-install y corregir el post-check en `plugins_install()`**

Dentro de `plugins_install()`, **antes** del bloque `echo "corriendo pnpm install..."`, agregar:

```bash
  echo "revisando si el stack a instalar afecta sesiones existentes..."
  local manifest_pkgs
  manifest_pkgs="$(node -e "
    const m = require('$DSH_MANIFEST');
    console.log(Object.keys(m.dependencies || {}).join('\n'));
  " 2>/dev/null)"
  local pkg any_impact=0
  for pkg in $manifest_pkgs; do
    local installed_dir="$profile_dir/node_modules/$pkg"
    [ -d "$installed_dir" ] || continue
    local guard_rc=0
    session_backup_guard install "$installed_dir" "$profile" || guard_rc=$?
    if [ "$guard_rc" -eq 3 ]; then
      any_impact=1
    fi
  done
  if [ "$any_impact" -eq 1 ]; then
    echo "creando backup automatico antes de instalar (trigger: plugins-install)..."
    DSH_TRIGGER="plugins-install" session_backup_create --only-at-risk \
      --label "preinstall-$(date -u +%Y%m%dT%H%M%SZ)" || {
      echo "fallo el backup automatico; abortando plugins-install" >&2
      return 1
    }
  fi
```

Y reemplazar el bloque final ya existente (después de `restart_dsh || return 1`):

```bash
  echo "revisando el impacto del stack instalado sobre las sesiones existentes..."
  local scan_rc=0
  session_backup_scan --profile "$profile" --fail-on-risk >/dev/null 2>&1 || scan_rc=$?
  if [ "$scan_rc" -eq 4 ]; then
    echo "⚠ hay sesiones 'broken' tras instalar el stack. Corré 'dsh-manage session-backup scan' para el detalle." >&2
  elif [ "$scan_rc" -eq 3 ]; then
    echo "ℹ hay sesiones 'at-risk' (dependen de un plugin recién instalado). Considerá 'dsh-manage session-backup create --only-at-risk'." >&2
  fi
```

- [ ] **Step 4: Correr los tests**

Run: `cd /opt/dsh-manage && bats tests/ && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): gate pre-install completo + post-check corregido en plugins-install"
```

---

### Task 6: `repair --mark-ignorable`

**Files:**
- Modify: `plugins/session-scan.py`
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `require_dsh_stopped()`, `session_backup_create()`, `invalidate_projcache_entry()` (Task 1); `load_baseline()`, `CHUNK_ROW_TAGS` (Fase 1+2).
- Produces: `repair_events()` (header excluido, **aborta si el artefacto está torn**), `find_session` (sin `grep` sobre `.zstd`), `session_backup_repair()` (**temporales fuera de `sessions/`**).

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "repair marca solo tipos desconocidos, preserva byte a byte lo demas Y el header" {
  install_fake_harness 48
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-rp1--" "session-rp1" "session-rp1" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{"x":  1}}' \
    '{"type":"foo/desconocido","seq":2,"time":2,"data":{}}' \
    '{"type":"tipo/2","seq":3,"time":3,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-repair-rp1
  run env DSH_PORT=39222 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --session session-rp1 --mark-ignorable --yes
  [ "$status" -eq 0 ]
  run bash -c "zstd -dc '$DSH_HOME/sessions/--ws-rp1--/session-rp1/session.jsonl.zstd' | sed -n '1p'"
  [[ "$output" != *"ignorable"* ]]
  [[ "$output" == *'"type":"session"'* ]]
  run bash -c "zstd -dc '$DSH_HOME/sessions/--ws-rp1--/session-rp1/session.jsonl.zstd' | sed -n '3p'"
  [[ "$output" == *'"ignorable": true'* ]]
  run bash -c "zstd -dc '$DSH_HOME/sessions/--ws-rp1--/session-rp1/session.jsonl.zstd' | sed -n '2p'"
  [[ "$output" == *'"x":  1'* ]]
}

@test "repair aborta sobre un artefacto con cola rota, no publica un archivo parcial" {
  install_fake_harness 48
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-rp5--" "session-rp5" "session-rp5" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}' \
    '{"type":"foo/desconocido","seq":2,"time":2,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-rp5
  # truncar el .zstd a la mitad para simular una escritura interrumpida
  artifact="$DSH_HOME/sessions/--ws-rp5--/session-rp5/session.jsonl.zstd"
  size="$(stat -c%s "$artifact")"
  head -c $((size / 2)) "$artifact" > "${artifact}.tmp"
  mv "${artifact}.tmp" "$artifact"
  original_content="$(cat "$artifact" | xxd | head -1)"
  run env DSH_PORT=39228 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --session session-rp5 --mark-ignorable --yes
  [ "$status" -ne 0 ]
  # el artefacto truncado no se toco (no se publico un "reparado" parcial)
  current_content="$(cat "$artifact" | xxd | head -1)"
  [ "$original_content" = "$current_content" ]
}

@test "repair exige DSH detenido" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-rp2--" "session-rp2" "session-rp2" \
    '{"type":"foo/x","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-rp2
  python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 39223))
s.listen(1)
time.sleep(2)
" &
  listener_pid=$!
  sleep 0.3
  run env DSH_PORT=39223 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --session session-rp2 --mark-ignorable --yes
  kill "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "repair sin --session falla (nunca en lote)" {
  install_fake_harness 48
  run env DSH_PORT=39224 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --mark-ignorable --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"--session"* ]]
}

@test "repair encuentra la sesion por id de header aunque el directorio no coincida" {
  install_fake_harness 48
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-rp4--" "67890" "session-67890" \
    '{"type":"foo/x","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-rp4
  run env DSH_PORT=39226 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --session session-67890 --mark-ignorable --yes
  [ "$status" -eq 0 ]
  run bash -c "zstd -dc '$DSH_HOME/sessions/--ws-rp4--/67890/session.jsonl.zstd' | sed -n '2p'"
  [[ "$output" == *'"ignorable": true'* ]]
}

@test "repair hace backup implicito antes de tocar la sesion y no deja temporales bajo sessions/" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-rp3--" "session-rp3" "session-rp3" \
    '{"type":"foo/x","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-rp3
  before_count="$(find "$DSH_BACKUP_ROOT" -maxdepth 1 -type d ! -name '*.partial' | wc -l)"
  run env DSH_PORT=39225 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup repair --session session-rp3 --mark-ignorable --yes
  [ "$status" -eq 0 ]
  after_count="$(find "$DSH_BACKUP_ROOT" -maxdepth 1 -type d ! -name '*.partial' | wc -l)"
  [ "$after_count" -gt "$before_count" ]
  # sin restos .repair-plain / .repair-tmp bajo sessions/
  leftovers="$(find "$DSH_HOME/sessions" -name '*.repair-*' 2>/dev/null | wc -l)"
  [ "$leftovers" -eq 0 ]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `repair` no es un subcomando válido.

- [ ] **Step 3: Agregar `repair_events` (con chequeo de cola rota) y `find_session` al helper Python**

Agregar a `plugins/session-scan.py`, antes de `main()`:

```python
def repair_events(artifact, baseline, allowed_types=None):
    """Marca ignorable:true SOLO en lineas fuera del baseline. El HEADER
    (primera linea, type=session) NUNCA se toca.

    Aborta (SystemExit) si el artefacto esta TORN (zstd -dc con
    returncode != 0): read_session_events() (uso de solo lectura, scan) SI
    tolera una cola rota porque el harness la descarta al cargar -- pero
    repair REESCRIBE el artefacto, y publicar solo el fragmento recuperado
    como si fuera el log completo seria perder la cola para siempre sin
    aviso. Verificado: un artefacto truncado al 70% da returncode=1 y datos
    parciales que parecen "normales" si no se chequea el codigo de salida.
    """
    if artifact.endswith(".zstd"):
        proc = subprocess.run(["zstd", "-dc", artifact], capture_output=True)
        if proc.returncode != 0:
            raise SystemExit(
                f"el artefacto {artifact} tiene una cola rota (zstd -dc "
                f"rc={proc.returncode}). repair no puede reescribir un log "
                f"truncado sin arriesgar perder la cola -- usar restore "
                f"desde un snapshot previo en su lugar."
            )
        raw = proc.stdout.decode("utf-8", errors="replace")
    else:
        with open(artifact, encoding="utf-8", errors="replace") as f:
            raw = f.read()
    lines = raw.splitlines()
    out = []
    marked = 0
    header_seen = False
    for line in lines:
        if not line.strip():
            out.append(line)
            continue
        try:
            row = json.loads(line)
        except ValueError:
            out.append(line)
            continue
        kind = row.get("type")
        if not header_seen and kind == "session":
            header_seen = True
            out.append(line)
            continue
        is_chunk_row = kind in CHUNK_ROW_TAGS
        already_ok = kind in baseline or row.get("ignorable") is True or is_chunk_row
        if already_ok:
            out.append(line)
            continue
        if allowed_types is not None and kind not in allowed_types:
            out.append(line)
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


def cmd_find_session(args):
    """Resuelve una sesion por directorio O por id-de-header, descomprimiendo
    (nunca grep sobre binarios .zstd, que no puede leerlos)."""
    sessions_dir = args.sessions
    ref = args.ref
    for ws in sorted(os.listdir(sessions_dir)):
        wsd = os.path.join(sessions_dir, ws)
        if not os.path.isdir(wsd):
            continue
        for d in sorted(os.listdir(wsd)):
            dpath = os.path.join(wsd, d)
            if not os.path.isdir(dpath):
                continue
            if d == ref:
                print(dpath)
                return
            for name in ("session.jsonl.zstd", "session.jsonl"):
                art = os.path.join(dpath, name)
                if not os.path.isfile(art):
                    continue
                if art.endswith(".zstd"):
                    raw = subprocess.run(["zstd", "-dc", art], capture_output=True).stdout.decode("utf-8", errors="replace")
                else:
                    with open(art, encoding="utf-8", errors="replace") as f:
                        raw = f.read()
                first_line = raw.splitlines()[0] if raw else ""
                try:
                    header = json.loads(first_line)
                except ValueError:
                    continue
                if header.get("id") == ref:
                    print(dpath)
                    return
    raise SystemExit(1)
```

y su registro en `main()`:

```python
    p = sub.add_parser("repair", help="marca eventos huerfanos como ignorable (uso interno)")
    p.add_argument("--artifact", required=True)
    p.add_argument("--harness", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--types", default=None)
    p.set_defaults(func=cmd_repair)

    p = sub.add_parser("find-session", help="resuelve una sesion por dir o id (uso interno)")
    p.add_argument("--sessions", required=True)
    p.add_argument("--ref", required=True)
    p.set_defaults(func=cmd_find_session)
```

- [ ] **Step 4: Escribir `session_backup_repair()` en bash (temporales fuera de `sessions/`)**

Agregar a `dsh-manage.sh`, después de `plugins_remove()`:

```bash
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
  local artifact_dir
  artifact_dir="$(python3 "$DSH_MANAGE_DIR/plugins/session-scan.py" find-session --sessions "$sessions_dir" --ref "$session")" || {
    echo "no se encontro la sesion '$session' bajo $sessions_dir" >&2
    return 1
  }
  local artifact_file=""
  for f in "session.jsonl.zstd" "session.jsonl"; do
    [ -f "$artifact_dir/$f" ] && artifact_file="$artifact_dir/$f"
  done
  [ -n "$artifact_file" ] || { echo "sin artefacto de sesion en $artifact_dir" >&2; return 1; }

  echo "creando backup antes de reparar..."
  local backup_rc=0
  session_backup_create --label "pre-repair-$(basename "$session")-$(date -u +%Y%m%dT%H%M%SZ)" || backup_rc=$?
  if [ "$backup_rc" -ne 0 ] && [ "$backup_rc" -ne 2 ]; then
    echo "fallo el backup previo (rc=$backup_rc); abortando repair sin tocar nada" >&2
    return 1
  fi

  umask 077
  # Los temporales viven en un scratch bajo DSH_BACKUP_ROOT, NUNCA bajo
  # sessions/ (invariante S5.1). Mismo filesystem que sessions/ (confirmado
  # mismo device id), asi que el mv -T final sigue siendo atomico.
  local scratch="$DSH_BACKUP_ROOT/.repair-scratch"
  mkdir -p "$scratch"
  local work_id
  work_id="$(basename "$artifact_file")-$$-$(date -u +%s)"
  local out_plain="$scratch/${work_id}.plain"
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

  local new_artifact="$scratch/${work_id}.repaired"
  if [[ "$artifact_file" == *.zstd ]]; then
    zstd -q -f -o "$new_artifact" "$out_plain" || { rm -f "$out_plain" "$new_artifact"; return 1; }
  else
    cp "$out_plain" "$new_artifact"
  fi
  rm -f "$out_plain"

  local orig_lines new_lines orig_header new_header
  if [[ "$artifact_file" == *.zstd ]]; then
    zstd -t "$new_artifact" >/dev/null 2>&1 || { echo "el archivo reparado no valida (zstd -t), abortando" >&2; rm -f "$new_artifact"; return 1; }
    orig_lines="$(zstd -dc "$artifact_file" | wc -l)"
    new_lines="$(zstd -dc "$new_artifact" | wc -l)"
    orig_header="$(zstd -dc "$artifact_file" | head -1)"
    new_header="$(zstd -dc "$new_artifact" | head -1)"
  else
    orig_lines="$(wc -l < "$artifact_file")"
    new_lines="$(wc -l < "$new_artifact")"
    orig_header="$(head -1 "$artifact_file")"
    new_header="$(head -1 "$new_artifact")"
  fi
  if [ "$orig_lines" != "$new_lines" ] || [ "$orig_header" != "$new_header" ]; then
    echo "el archivo reparado no preserva lineas/header original, abortando" >&2
    rm -f "$new_artifact"
    return 1
  fi

  require_dsh_stopped || { echo "dsh arranco durante el repair; abortando antes de publicar" >&2; rm -f "$new_artifact"; return 1; }

  mv -T "$new_artifact" "$artifact_file"
  invalidate_projcache_entry "$session" || true
  rmdir "$scratch" 2>/dev/null || true

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

- [ ] **Step 6: Re-confirmar el gate contra la sesión real**

```bash
cd /opt/dsh-manage
./dsh-manage.sh session-backup create --label antes-de-repair-real
systemctl stop dsh.service
./dsh-manage.sh session-backup repair --session session-67436620-4931-423a-aeac-3b7eb7b03ec9 --mark-ignorable --yes
systemctl start dsh.service
node -e "
const sessionLib = require('$HOME/.local/dsh-node/node24/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js');
const raw = require('child_process').execSync('zstd -dc \"$HOME/.dsh/sessions/--opt-vpn-monitor-mke--/session-67436620-4931-423a-aeac-3b7eb7b03ec9/session.jsonl.zstd\"', {maxBuffer: 1024*1024*50}).toString('utf-8');
const lines = raw.split('\n').filter(Boolean);
const KNOWN = sessionLib.KNOWN_SESSION_EVENT_TYPES;
let rejected = 0;
for (const line of lines) {
  const row = JSON.parse(line);
  if (row.type === 'session') continue;
  const events = sessionLib.decodeStorageRecord(row);
  for (const ev of events) {
    if (!KNOWN.has(ev.type) && ev.ignorable !== true) rejected++;
  }
}
console.log('rejected:', rejected, '(esperado: 0)');
"
find "$HOME/.dsh/sessions" -name '*.repair-*' -o -name '*repair-plain*' -o -name '*repair-tmp*'
```
Expected: `N eventos marcados ignorable:true`, `rejected: 0`, y el `find` final **sin salida** (ningún resto bajo `sessions/`).

- [ ] **Step 7: Commit**

```bash
git add plugins/session-scan.py dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): subcomando repair --mark-ignorable, header excluido, aborta ante cola rota"
```

---

### Task 7: Versión y documentación

**Files:**
- Modify: `dsh-manage.sh`, `CHANGELOG.md`, `README.md`, `tests/session-backup.bats`
- Test: `tests/session-backup.bats`

- [ ] **Step 1: Bump de versión y arreglo del test heredado**

Antes de tocar nada, correr `grep -n 'DSH_MANAGE_VERSION=' dsh-manage.sh` para confirmar la versión real vigente en `main` en este momento (al escribir este plan es `1.3.0`, por un cambio externo no relacionado con session-backup — ver nota en Global Constraints). Bumpear al siguiente patch/minor libre (`1.4.0` si la vigente sigue siendo `1.3.0`). **En el mismo commit**, actualizar el test que afirma la versión anterior en `tests/session-backup.bats` a la nueva.

- [ ] **Step 2: Correr los tests**

Run: `cd /opt/dsh-manage && bats tests/`
Expected: PASS.

- [ ] **Step 3: CHANGELOG**

Insertar antes de `## [1.2.0] - 2026-08-25`:

```markdown
## [Unreleased]

### Agregado

- `dsh-manage session-backup restore` — restaura sesiones desde un snapshot,
  con backup implícito previo (tolera "nada que respaldar"), exige DSH
  detenido (verificado dos veces), escritura atómica. `--session` limita a
  una sola sesión, `--to-new-id` restaura como sesión nueva reescribiendo el
  `id` del header, `--force` es obligatorio para pisar un destino que difiere.
  El nombre de snapshot pasado a `--from` (incluido `latest`) se resuelve a
  una ruta absoluta antes de cualquier operación que pueda cambiar a qué
  apunta `latest`.
- `dsh-manage session-backup prune` — borra snapshots viejos (`--keep` /
  `--older-than`), con protección **por sesión individual**: nunca borra la
  única copia de una sesión `broken`, incluso cuando varios candidatos a
  borrar comparten esa sesión entre sí.
- `dsh-manage session-backup repair --mark-ignorable` — marca eventos
  huérfanos como `ignorable:true` in-place, sin tocar nunca el header.
  Aborta sin publicar nada si el artefacto de origen tiene una cola rota
  (evita reescribir un log truncado y perder la cola para siempre). Lossy,
  nunca en lote, copia byte a byte todo lo que no marca, y no deja
  temporales bajo `sessions/`. Gate de validación superado contra la sesión
  real de `vpn-monitor-mke`.
- `dsh-manage plugins-remove <paquete> [profile] [--yes]` — gate de
  resguardo (`session_backup_guard`, solo lectura) antes de `pnpm remove`,
  backup automático si detecta impacto, confirmación explícita obligatoria.
- `plugins-install` corre el gate de resguardo **antes** de instalar.

### Corregido

- `restart_dsh()` extraída de `plugins_install()` para compartirla con
  `plugins_remove()`.
- Los 2 warnings `SC2181` preexistentes en `tests/session-backup.bats`
  quedan saneados — `make check` vuelve a pasar limpio de punta a punta.
```

- [ ] **Step 4: README**

Ampliar la tabla de comandos y la sección `### session-backup: resguardo de sesiones` con los nuevos subcomandos, siguiendo el mismo estilo ya existente en el archivo.

- [ ] **Step 5: Verificación final completa**

Run: `cd /opt/dsh-manage && make check && make bats`
Expected: shellcheck limpio, todos los tests verdes.

- [ ] **Step 6: Commit**

```bash
git add dsh-manage.sh CHANGELOG.md README.md tests/session-backup.bats
git commit -m "docs(session-backup): documentar restore/prune/repair/plugins-remove + bump de version"
```

---

## Self-Review

**1. Cobertura de los 17 bloqueantes del arbitraje formal + 5 hallazgos detectados durante la escritura final (D1, R1, R5, P4, P5)**

| # | Bloqueante | Dónde se resuelve |
|---|---|---|
| D1 | `--from latest` resuelto con `readlink -f` antes del backup implícito | Task 1 |
| R1 | `repair` aborta ante artefacto torn, no publica un log parcial | Task 6 |
| R5 | Temporales de `repair` fuera de `sessions/` (scratch en `DSH_BACKUP_ROOT`) | Task 6 |
| P4 | `restart_dsh` solo corre si el profile tocado es `web` (el único servido por `dsh.service`) | Task 4 |
| P5 | `printf '%s'` en vez de `echo` para el label automático (evita guión colgante) | Task 4 |
| A1 | `prune` protección por-sesión | Task 2 |
| V7/A5 | `guard_rc=$?`/`post_rc=$?` bajo `set -e` (2 sitios) | Task 4 |
| A2 | `restore`/`repair` aceptan rc=0/2 del backup implícito | Tasks 1 y 6 |
| V11 | `--to-new-id` reescribe el `id` del header | Task 1 |
| V1 | `session_backup_scan --profile`, nunca posicional | Tasks 4 y 5 |
| V8 | Header excluido de `repair_events` | Task 6 |
| V6/R2 | Búsqueda de sesión sin `grep` sobre `.zstd` | Task 6 |
| A3 + V9 | `SC2181` heredados + `mapfile` | Task 2 |
| #2/M-1 | `--force` obligatorio | Task 1 |
| #5 | Contrato `session_backup_guard` 0/1/3 | Task 3 |
| #7 | Gate pre-install completo | Task 5 |
| V10 | Test de `plugins_remove` con profile dir real | Task 4 |
| #12 | Test de versión actualizado en el bump | Task 7 |
| #15 | `source --lib` | Task 3 |
| #8 | Test de Task 5 con comportamiento real | Task 5 |
| #1 | `read_stable_bytes()` eliminada | Global Constraints |

**2. Placeholders**: ninguno. Los fixes más críticos (D1, R1, R5, P4, A1, A2, V7/A5, V8, V6, V11) fueron validados ejecutándolos en sandboxes descartables o leyendo el código real (`dsh.service` unit) antes de escribirse.

**3. Consistencia**: `require_dsh_stopped()` (Task 1) reutilizada en Task 6. `invalidate_projcache_entry()` con igualdad exacta de `id`. `restart_dsh()` (Task 4) usada por `plugins_install()` (Task 5, siempre corre porque ese hook solo aplica al profile `web`) y `plugins_remove()` (condicionada a `profile = "web"`, único profile que `dsh.service` sirve). `session_backup_guard()` (Task 3) con contrato 0/1/3 fijo, consumida simétricamente por Task 4 (`remove`) y Task 5 (`install`). `repair_events()` (Task 6) ahora propaga el estado torn en vez de ignorarlo.

**4. Nota sobre las críticas tardías recibidas durante la escritura**: durante la redacción final de esta v2 llegaron varios reportes de un swarm de revisión ya formalmente cerrado (rondas 4, 5 y 6, sobre `restore`, `repair` y `plugins_remove` respectivamente). La mayoría de sus hallazgos (D2, D3, D4, R2, R3, R4, P1, P2, P3) ya estaban resueltos en esta v2 porque coincidían con hallazgos ya aplicados del arbitraje formal — el swarm crítico solo tenía visibilidad de la v1. Se verificó cada hallazgo de forma independiente antes de descartarlo o aplicarlo; **D1, R1, R5, P4 y P5 eran genuinamente nuevos** y se integraron con evidencia ejecutada.
