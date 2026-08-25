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
  [ "$?" -eq 0 ]
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
  [ "$?" -eq 0 ]
  python3 - "$BATS_TEST_TMPDIR/out.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["changed"] is False, (
    f"el vendorizado NO esta sincronizado con el harness real: "
    f"added={d['added']} removed={d['removed']}"
)
PY
}