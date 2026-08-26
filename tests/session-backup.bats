#!/usr/bin/env bats

# Tests de session-backup. Fixtures sinteticos: nunca se copian sesiones
# reales al repo (contienen prompts y rutas del host).

setup() {
  export DSH_MANAGE_HOME="$BATS_TEST_TMPDIR/home"
  export DSH_HOME="$BATS_TEST_TMPDIR/dsh-home"
  export DSH_NODE="$BATS_TEST_TMPDIR/node/bin"
  export DSH_BACKUP_ROOT="$DSH_HOME/session-backups"
  mkdir -p "$DSH_MANAGE_HOME" "$DSH_HOME/sessions" "$DSH_NODE"
  SCAN="$BATS_TEST_DIRNAME/../plugins/session-scan.py"
  # Ruta EXACTA que consulta session_backup_preflight (DSH_PREFIX=$DSH_NODE/..)
  HARNESS_DIR="$DSH_NODE/../lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib"
  mkdir -p "$HARNESS_DIR"
}

# Instala un harness falso con N tipos EN LA RUTA QUE EL SCRIPT CONSULTA.
install_fake_harness() {
  local n="${1:-48}" i
  {
    printf 'const KNOWN_SESSION_EVENT_TYPES = new Set([\n'
    printf '\t"assistant/chunk",\n'
    for ((i = 1; i < n; i++)); do printf '\t"tipo/%d",\n' "$i"; done
    printf ']);\n'
  } > "$HARNESS_DIR/index.js"
  echo "$HARNESS_DIR/index.js"
}

@test "baseline extrae los tipos del harness" {
  h="$(install_fake_harness 48)"
  run python3 "$SCAN" baseline --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"count": 48'* ]]
  [[ "$output" == *'assistant/chunk'* ]]
}

@test "baseline con un catalogo de tamaño distinto da un count distinto" {
  # B3: una implementacion que hardcodee count:48 pasaria el test de arriba
  # pero no este, que instala 25 tipos (>= piso de cordura) y exige count=25.
  h="$(install_fake_harness 25)"
  run python3 "$SCAN" baseline --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"count": 25'* ]]
  [[ "$output" != *'"count": 48'* ]]
}

@test "baseline con menos de 20 tipos es fallo duro" {
  h="$(install_fake_harness 5)"
  run python3 "$SCAN" baseline --harness "$h"
  [ "$status" -ne 0 ]
  [[ "$output" == *"piso de cordura"* ]]
}

@test "baseline compara contra el vendorizado y reporta diferencias" {
  h="$(install_fake_harness 48)"
  # vendorizado con un tipo de menos -> debe reportar changed y el added.
  # El fixture extrae la lista real del harness falso y quita el ULTIMO tipo,
  # de modo que el vendorizado es subconjunto estricto (removed siempre []).
  python3 - "$h" "$BATS_TEST_TMPDIR/known.json" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("new Set(["); j = src.index("])", i)
types = re.findall(r'"([^"]+)"', src[i:j])
json.dump({"types": sorted(types[:-1])}, open(sys.argv[2], "w"))
PY
  # Nota: `run` concatena stdout+stderr; el JSON va a stdout pero el script
  # emite un "aviso" por stderr cuando changed=true. Para validar el JSON lo
  # ejecutamos directo a un archivo separando stderr.
  python3 "$SCAN" baseline --harness "$h" \
      --known "$BATS_TEST_TMPDIR/known.json" \
      > "$BATS_TEST_TMPDIR/out.json" 2>"$BATS_TEST_TMPDIR/err.txt"
  rc=$?
  [ "$rc" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/out.json")" == *'"changed": true'* ]]
  # B2: el ultimo tipo extraido (tipo/47) es el que se quito del vendorizado;
  # debe aparecer en "added" (demuestra que el script leyo el harness real) y
  # "removed" debe ser [] (el vendorizado es subconjunto estricto). Se valida
  # parseando el JSON de salida en vez de un substring suelto.
  python3 - "$BATS_TEST_TMPDIR/out.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["changed"] is True, d
assert d["added"] == ["tipo/47"], d["added"]
assert d["removed"] == [], d["removed"]
PY
}

# M1: sincronizacion del vendorizado con el harness REAL del host. Es una
# verificacion post-deploy que depende del host, no del repo; si el harness
# real no esta presente (CI sin dsh instalado), se salta en vez de fallar.
@test "vendorizado sincronizado con el harness real del host (skip si ausente)" {
  # Path del harness instalado en este host (DSH_PREFIX/lib/.../dsh-session).
  if [ -z "$DSH_NODE" ] || [ ! -d "$DSH_NODE/../lib/node_modules/@deepseek-ai/dsh" ]; then
    skip "no hay harness real instalado en este host"
  fi
  real_harness="$DSH_NODE/../lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js"
  if [ ! -f "$real_harness" ]; then
    skip "no se encontro dsh-session/lib/index.js en el harness real"
  fi
  python3 "$SCAN" baseline --harness "$real_harness" \
      --known "$BATS_TEST_DIRNAME/../plugins/known-session-event-types.json" \
      > "$BATS_TEST_TMPDIR/out.json" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ]
  python3 - "$BATS_TEST_TMPDIR/out.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["changed"] is False, (
    f"el vendorizado NO esta sincronizado con el harness real: "
    f"added={d['added']} removed={d['removed']}"
)
PY
}

# Crea una sesion sintetica comprimida. $1=dir sessions, $2=workspace,
# $3=nombre-de-directorio, $4=id-en-el-header, $5..=lineas JSON.
fake_session() {
  local root="$1" ws="$2" dir="$3" sid="$4"; shift 4
  local d="$root/$ws/$dir"
  mkdir -p "$d"
  {
    printf '{"type":"session","version":0,"id":"%s","createdAt":1,"cwd":"/tmp/%s"}\n' "$sid" "$ws"
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } | zstd -q -o "$d/session.jsonl.zstd"
}

# Plugin falso que declara vocabulario, en layout pnpm REAL (top-level).
fake_plugin() {
  local nm="$1" name="$2" tipo="$3"
  mkdir -p "$nm/$name/lib"
  printf '{"name":"%s","version":"9.9.9"}\n' "$name" > "$nm/$name/package.json"
  cat > "$nm/$name/lib/index.js" <<EOF
import { KNOWN_SESSION_EVENT_TYPES } from "@deepseek-ai/dsh-session";
export function emit(session) { session.append("$tipo", {}); }
EOF
}

@test "sesion con solo tipos del baseline es ok" {
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-a--" "session-aaa" "session-aaa" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "ok"'* ]]
}

@test "las filas de chunks NO cuentan como tipos desconocidos" {
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-chunk--" "session-chunk" "session-chunk" \
    '{"type":"reasoning-chunks","seq0":5,"time0":1,"data":{"index":0,"texts":["a","b","c"],"dt":[1,1]}}' \
    '{"type":"text-chunks","seq0":9,"time0":2,"data":{"index":0,"texts":["x"],"dt":[]}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "ok"'* ]]
  # 3 + 1 chunks expandidos a assistant/chunk
  [[ "$output" == *'"events": 4'* ]]
}

@test "tipo desconocido sin dueno instalado es broken" {
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-b--" "session-bbb" "session-bbb" \
    '{"type":"foo/bar","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "broken"'* ]]
}

@test "tipo desconocido con plugin top-level que lo declara es at-risk" {
  h="$(install_fake_harness 48)"
  nm="$BATS_TEST_TMPDIR/nm"
  fake_plugin "$nm" "plugin-falso" "foo/bar"
  fake_session "$DSH_HOME/sessions" "--ws-c--" "session-ccc" "session-ccc" \
    '{"type":"foo/bar","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h" --profile-node-modules "$nm"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "at-risk"'* ]]
  [[ "$output" == *"plugin-falso@9.9.9"* ]]
}

@test "el vocabulario solo cuenta literales de append, no de ctx.on" {
  h="$(install_fake_harness 48)"
  nm="$BATS_TEST_TMPDIR/nm"
  mkdir -p "$nm/plugin-listener/lib"
  printf '{"name":"plugin-listener","version":"1.0.0"}\n' > "$nm/plugin-listener/package.json"
  cat > "$nm/plugin-listener/lib/index.js" <<'EOF'
import { KNOWN_SESSION_EVENT_TYPES } from "@deepseek-ai/dsh-session";
export function apply(ctx) { ctx.on("agente/inventado", () => {}); }
EOF
  fake_session "$DSH_HOME/sessions" "--ws-d--" "session-ddd" "session-ddd" \
    '{"type":"agente/inventado","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h" --profile-node-modules "$nm"
  [ "$status" -eq 0 ]
  # ctx.on no declara vocabulario: sigue siendo broken, sin dueno falso
  [[ "$output" == *'"risk": "broken"'* ]]
  [[ "$output" != *"plugin-listener"* ]]
}

@test "ignorable true hace que el tipo desconocido no cuente" {
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-e--" "session-eee" "session-eee" \
    '{"type":"foo/bar","seq":1,"time":1,"ignorable":true,"data":{}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "ok"'* ]]
}

@test "ignorable null NO cuenta como ignorable (regresion vpn-monitor)" {
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-f--" "session-fff" "session-fff" \
    '{"type":"foo/bar","seq":1,"time":1,"ignorable":null,"data":{}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "broken"'* ]]
}

@test "scan emite el directorio real, distinto del id del header" {
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-g--" "67436620" "session-67436620" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"directory": "67436620"'* ]]
  [[ "$output" == *'"id": "session-67436620"'* ]]
}

@test "fail-on-risk sale 4 si hay broken" {
  h="$(install_fake_harness 48)"
  fake_session "$DSH_HOME/sessions" "--ws-h--" "session-hhh" "session-hhh" \
    '{"type":"foo/bar","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$DSH_HOME/sessions" --harness "$h" --fail-on-risk
  [ "$status" -eq 4 ]
}

@test "session-backup sin subcomando imprime uso y falla" {
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup
  [ "$status" -ne 0 ]
  [[ "$output" == *"uso:"* ]]
  [[ "$output" == *"scan"* ]]
}

@test "session-backup scan sin sesiones no falla" {
  install_fake_harness 48
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 sesiones"* ]]
}

@test "session-backup scan imprime la tabla sin traceback" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-t--" "session-ttt" "session-ttt" \
    '{"type":"foo/bar","seq":1,"time":1,"data":{}}'
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace"* ]]
  [[ "$output" == *"session-ttt"* ]]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" != *"SyntaxError"* ]]
}

@test "session-backup scan acepta --profile con valor" {
  install_fake_harness 48
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup scan --profile repro
  [ "$status" -eq 0 ]
}

@test "session-backup scan rechaza --profile sin valor" {
  install_fake_harness 48
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup scan --profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"--profile"* ]]
}

@test "create produce snapshot con manifest, checksums y vocabulary verificables" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-x--" "session-xxx" "session-xxx" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label prueba
  [ "$status" -eq 0 ]
  snap="$(ls -d "$DSH_BACKUP_ROOT"/*-prueba)"
  [ -f "$snap/MANIFEST.json" ]
  [ -f "$snap/CHECKSUMS.sha256" ]
  [ -f "$snap/vocabulary.json" ]
  [ -f "$snap/sessions/--ws-x--/session-xxx/session.jsonl.zstd" ]
  ( cd "$snap" && sha256sum -c CHECKSUMS.sha256 )
  python3 -c "
import json,sys
v=json.load(open('$snap/vocabulary.json'))
assert len(v['baseline'])==48, v
"
}

@test "create preserva el nombre real del directorio, no el id del header" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-y--" "67436620" "session-67436620" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label opaco
  [ "$status" -eq 0 ]
  snap="$(ls -d "$DSH_BACKUP_ROOT"/*-opaco)"
  [ -f "$snap/sessions/--ws-y--/67436620/session.jsonl.zstd" ]
}

@test "create no modifica nada bajo sessions/ (contenido ni metadata)" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-z--" "session-zzz" "session-zzz" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  before="$(find "$DSH_HOME/sessions" \( -type f -o -type d \) -printf '%p %s %m\n' | sort; \
            find "$DSH_HOME/sessions" -type f -exec sha256sum {} + | sort)"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label limpio
  [ "$status" -eq 0 ]
  after="$(find "$DSH_HOME/sessions" \( -type f -o -type d \) -printf '%p %s %m\n' | sort; \
           find "$DSH_HOME/sessions" -type f -exec sha256sum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "create sin nada que respaldar sale 2 y no publica" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-ok--" "session-ok" "session-ok" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --only-at-risk --label vacio
  [ "$status" -eq 2 ]
  [[ "$output" == *"nada que respaldar"* ]]
  run bash -c "ls -d '$DSH_BACKUP_ROOT'/*-vacio 2>/dev/null"
  [ "$status" -ne 0 ]
}

@test "create rechaza un label con traversal" {
  install_fake_harness 48
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label '../../etc'
  [ "$status" -ne 0 ]
  [[ "$output" == *"label"* ]]
}

@test "list muestra el snapshot valido, ignora .partial y avisa de ellos" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-l--" "session-lll" "session-lll" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label listable
  mkdir -p "$DSH_BACKUP_ROOT/20260101T000000Z-fallido.partial"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup list
  [ "$status" -eq 0 ]
  [[ "$output" == *"listable"* ]]
  [[ "$output" != *"fallido"* ]]
  [[ "$output" == *".partial"* ]]
}

@test "verify valida el snapshot creado" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-v--" "session-vvv" "session-vvv" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label verificable
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup verify --from latest
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "verify detecta un artefacto corrupto" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-c2--" "session-c2" "session-c2" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label corrupto
  snap="$(ls -d "$DSH_BACKUP_ROOT"/*-corrupto)"
  printf 'basura' > "$snap/sessions/--ws-c2--/session-c2/session.jsonl.zstd"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup verify --from "$(basename "$snap")"
  [ "$status" -ne 0 ]
}

@test "list no duplica el snapshot apuntado por latest" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-dup--" "session-dup" "session-dup" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label unico
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup list
  [ "$status" -eq 0 ]
  # debe aparecer UNA sola vez el label, no dos (una por el dir real, otra por 'latest')
  count="$(printf '%s\n' "$output" | grep -c "unico")"
  [ "$count" -eq 1 ]
}

@test "create rechaza un label con newline embebido" {
  install_fake_harness 48
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label $'ok\n../../tmp/evil'
  [ "$status" -ne 0 ]
  [[ "$output" == *"label"* ]]
}

@test "el manifest documenta los plugins que escriben eventos de sesion" {
  run python3 - "$BATS_TEST_DIRNAME/../plugins/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
w = m.get("sessionEventWriters")
assert w, "falta la clave sessionEventWriters"
sp = w.get("dsh-swarm-panel")
assert sp, "dsh-swarm-panel no esta declarado como event writer"
assert "swarm/" in sp.get("prefixes", []), sp
assert "harness" in sp.get("note", "").lower(), "la nota debe aclarar que el fix es del harness"
PY
  [ "$status" -eq 0 ]
}

@test "el manifest del snapshot registra la version de dsh-manage" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-ver--" "session-ver" "session-ver" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label version
  snap="$(ls -d "$DSH_BACKUP_ROOT"/*-version)"
  run python3 -c "
import json
m = json.load(open('$snap/MANIFEST.json'))
assert m['dshManageVersion'] == '1.2.0', m['dshManageVersion']
"
  [ "$status" -eq 0 ]
}

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

@test "restore sin --force no pisa un destino que difiere (por corrupcion, el backup implicito ya aborta antes)" {
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

@test "restore sin --force no pisa un destino VALIDO que difiere (ejercita el chequeo del loop, no el del backup)" {
  install_fake_harness 48
  fake_session "$DSH_HOME/sessions" "--ws-r7--" "session-r7" "session-r7" \
    '{"type":"tipo/1","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label pre-r7
  # Reescribimos la sesion con un .zstd VALIDO pero de contenido distinto
  # (agrega un evento) -- a diferencia del test anterior, esto NO corrompe
  # el artefacto, asi que el backup implicito (que corre verify_dir/zstd -t)
  # tiene EXITO (rc=0). El flujo debe llegar entonces al chequeo real del
  # loop (comparacion de sha256 vs --force), que es lo que este test
  # verifica -- sin esto, un bug que borrara el chequeo del loop pasaria
  # inadvertido porque el chequeo del backup implicito produce el mismo
  # mensaje "--force" por una razon distinta.
  {
    printf '{"type":"session","version":0,"id":"session-r7","createdAt":1,"cwd":"/tmp/--ws-r7--"}\n'
    printf '{"type":"tipo/1","seq":1,"time":1,"data":{}}\n'
    printf '{"type":"tipo/2","seq":2,"time":2,"data":{}}\n'
  } | zstd -q -f -o "$DSH_HOME/sessions/--ws-r7--/session-r7/session.jsonl.zstd"
  run zstd -t "$DSH_HOME/sessions/--ws-r7--/session-r7/session.jsonl.zstd"
  [ "$status" -eq 0 ]
  content_antes="$(zstd -dc "$DSH_HOME/sessions/--ws-r7--/session-r7/session.jsonl.zstd")"
  run env DSH_PORT=39229 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup restore --from latest --session session-r7
  [ "$status" -ne 0 ]
  [[ "$output" == *"'$DSH_HOME/sessions/--ws-r7--/session-r7/session.jsonl.zstd' existe y difiere del snapshot; use --force para pisarlo"* ]]
  content_despues="$(zstd -dc "$DSH_HOME/sessions/--ws-r7--/session-r7/session.jsonl.zstd")"
  [ "$content_antes" = "$content_despues" ]
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
