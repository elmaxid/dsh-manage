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

@test "baseline con menos de 20 tipos es fallo duro" {
  h="$(install_fake_harness 5)"
  run python3 "$SCAN" baseline --harness "$h"
  [ "$status" -ne 0 ]
  [[ "$output" == *"piso de cordura"* ]]
}

@test "baseline compara contra el vendorizado y reporta diferencias" {
  h="$(install_fake_harness 48)"
  # vendorizado con un tipo de menos -> debe reportar changed y el added
  python3 - "$h" "$BATS_TEST_TMPDIR/known.json" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("new Set(["); j = src.index("])", i)
types = re.findall(r'"([^"]+)"', src[i:j])
json.dump({"types": sorted(types[:-1])}, open(sys.argv[2], "w"))
PY
  run python3 "$SCAN" baseline --harness "$h" --known "$BATS_TEST_TMPDIR/known.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"changed": true'* ]]
}