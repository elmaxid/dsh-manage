# Session Backup (Fase 1+2) Implementation Plan — v2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agregar `dsh-manage session-backup` con los subcomandos read-only y de snapshot (`scan`, `create`, `list`, `verify`).

**Architecture:** Un bloque de funciones nuevas en `dsh-manage.sh` (mismo estilo que `plugins_install`/`service_install`), más un helper Python que hace el trabajo pesado de JSON/zstd (mismo patrón que `plugins/merge-pnpm-workspace.py`). El baseline de tipos de evento se extrae parseando el harness instalado, nunca se hardcodea. **Este plan es read-only sobre el host**: lo único que escribe es su propio `$DSH_HOME/session-backups/`.

**Tech Stack:** bash (`set -euo pipefail`), python3 + zstd/sha256sum/flock, bats-core.

**Spec:** `docs/SESSION-BACKUP-DESIGN.md` (fases 1 y 2 de §7, más la enmienda §7.2)

---

## Por qué esta es la v2 (leer antes de implementar)

La v1 de este plan fue sometida a revisión por tres críticos y un árbitro, y **se refutó**. Dos fallos de fondo, ambos verificados ejecutando código contra el host real:

1. **El backend JSONL empaqueta ráfagas de chunks en *filas de almacenamiento***, no en eventos: `{"type":"reasoning-chunks","seq0":…,"time0":…,"data":{…}}` — envelope con `seq0`, sin `seq`. `decodeStorageRecord` las expande a `assistant/chunk` (que **sí** está en el baseline) *antes* del chequeo de tipos. La v1 leía el `.jsonl` crudo y las contaba como tipos desconocidos: **clasificaba mal 55 de 71 sesiones** (marcaba 60 en riesgo cuando hay 5). Eso destruía el producto, porque el `scan` *es* toda la Fase 1.

2. **`Session.append()` descarta el flag `ignorable`** en `dsh-session@0.1.1-rc.2` (verificado en `lib/index.js:1444`: el envelope se arma solo con `sourceEventSeqs` y `surfaceOp`). La v1 tenía una tarea que parcheaba `dsh-swarm-panel` para que emitiera `ignorable: true` y reiniciaba `dsh.service` — **habría reiniciado producción con colegas trabajando a cambio de cero efecto**. Esa tarea se eliminó. El fix real es del harness (existe solo en master, ninguna rc publicada lo trae), no del plugin.

Ambos puntos están cerrados en esta versión. El resto de las correcciones va marcado en cada tarea.

---

## Global Constraints

- Bash con `set -euo pipefail`; shellcheck debe pasar limpio (`make check`).
- Comentarios y salida al usuario en español, igual que el resto del script.
- **Ninguna función de este plan escribe bajo `$DSH_HOME/sessions/`.** Ni un `.bak`, ni un temp.
- `DSH_HOME` = config real de dsh (default `$HOME/.dsh`). `DSH_MANAGE_HOME` = dir de trabajo del script (default `$HOME/dsh-test`). No confundirlas.
- Backup root default: `$DSH_HOME/session-backups` — hermano de `sessions/`, nunca hijo.
- Permisos: `umask 077` al inicio de cada subcomando que escriba; directorios `0700`, archivos `0600`.
- Baseline verificado hoy: **48** tipos en `KNOWN_SESSION_EVENT_TYPES`. Piso de cordura: **20** (menos que eso = fallo duro).
- `ignorable` cuenta **solo** si es exactamente `true` (booleano). `null` y `"true"` NO cuentan.
- **Filas de almacenamiento**: `text-chunks`, `reasoning-chunks`, `tool-call-chunks` NO son eventos — se expanden a `assistant/chunk` antes de clasificar.
- Ruta del harness: `$DSH_PREFIX/lib/node_modules/$DSH_PKG/node_modules/@deepseek-ai/dsh-session/lib/index.js`.
- **Nunca poner `\"` dentro de un f-string de Python embebido en bash.** Usar heredoc `<<'PY'` y pasar los datos por `argv`, no por stdin (el heredoc ocupa stdin).
- Fases 3-5 (`restore`, `repair`, `prune`, integración con `plugins-remove`) están **fuera de alcance**, y con ellas la enmienda §7.2 (invalidar `session_projcache.json`), que pertenece al plan de `restore`.

## Interfaz incluida en Fase 1+2

Implementada: `scan` (`--profile`, `--fail-on-risk`), `create` (`--profile`, `--label`, `--only-at-risk`), `list`, `verify` (`--from`), y `DSH_BACKUP_ROOT` por variable de entorno.

Postergada a Fase 3 (declarado, no omitido): `--json`, `--quiet`, `--dry-run`, `--reason`, `--workspace`, `--session`, `--include-live` + lectura estable de logs vivos, `--no-dedup`, y los subcomandos `restore`/`repair`/`prune`.

---

## File Structure

| Archivo | Responsabilidad |
|---|---|
| `plugins/session-scan.py` (crear) | Trabajo pesado: baseline, decodificación de filas, vocabulario de plugins, clasificación, y armado del snapshot. Emite JSON. |
| `dsh-manage.sh` (modificar) | Subcomandos `session-backup {scan,create,list,verify}` + dispatcher. Orquesta, no parsea JSON a mano. |
| `plugins/known-session-event-types.json` (crear) | Baseline vendorizado, como fuente de comparación (avisa si el harness cambió). |
| `plugins/manifest.json` (modificar) | Clave `sessionEventWriters` documentando el hallazgo del harness. |
| `tests/session-backup.bats` (crear) | Tests con fixtures sintéticos. |
| `README.md`, `CHANGELOG.md`, `dsh-manage.sh` (modificar) | Documentación y bump a 1.2.0. |

---

### Task 1: Baseline del harness

**Files:**
- Create: `plugins/session-scan.py`
- Create: `plugins/known-session-event-types.json`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Produces: `extract_baseline(harness_path) -> list[str]`. CLI `session-scan.py baseline --harness <ruta> [--known <ruta>]` → JSON `{"types":[…],"count":N,"changed":bool,"added":[…],"removed":[…]}`. Sale 1 si `count < 20`.

- [ ] **Step 1: Escribir los tests que fallan**

Crear `tests/session-backup.bats`:

```bash
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
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `plugins/session-scan.py` no existe.

- [ ] **Step 3: Escribir la implementación**

Crear `plugins/session-scan.py`:

```python
#!/usr/bin/env python3
"""Helper de `dsh-manage session-backup`: extrae el baseline de tipos de
evento del harness, escanea el vocabulario de los plugins instalados, lee los
logs de sesion y clasifica el riesgo. Emite JSON a stdout.

Nunca escribe bajo $DSH_HOME/sessions/ — es de solo lectura sobre las sesiones.
"""
import argparse
import json
import os
import re
import subprocess
import sys

# Piso de cordura: un baseline vacio marcaria TODA sesion como `broken` e
# induciria un repair masivo destructivo. Menos de esto = fallo duro.
BASELINE_FLOOR = 20


def extract_baseline(harness_path):
    """Parsea `const KNOWN_SESSION_EVENT_TYPES = new Set([...])` del harness."""
    with open(harness_path, encoding="utf-8") as f:
        src = f.read()
    marker = "const KNOWN_SESSION_EVENT_TYPES = new Set(["
    start = src.find(marker)
    if start == -1:
        raise SystemExit("no se encontro KNOWN_SESSION_EVENT_TYPES en el harness")
    end = src.find("])", start)
    if end == -1:
        raise SystemExit("literal KNOWN_SESSION_EVENT_TYPES sin cierre")
    return re.findall(r'"([^"]+)"', src[start:end])


def load_baseline(harness_path):
    """Baseline validado contra el piso de cordura."""
    types = extract_baseline(harness_path)
    if len(types) < BASELINE_FLOOR:
        raise SystemExit(
            f"baseline con solo {len(types)} tipos, por debajo del piso de cordura "
            f"({BASELINE_FLOOR}): el harness cambio de formato o el parseo fallo. "
            "Abortando para no clasificar todo como roto."
        )
    return set(types)


def cmd_baseline(args):
    types = sorted(load_baseline(args.harness))
    out = {"types": types, "count": len(types), "changed": False,
           "added": [], "removed": []}
    if args.known and os.path.isfile(args.known):
        with open(args.known, encoding="utf-8") as f:
            known = set(json.load(f).get("types", []))
        added = sorted(set(types) - known)
        removed = sorted(known - set(types))
        out["changed"] = bool(added or removed)
        out["added"], out["removed"] = added, removed
        if out["changed"]:
            print(
                f"aviso: el catalogo del harness cambio respecto al vendorizado "
                f"(+{len(added)} / -{len(removed)})",
                file=sys.stderr,
            )
    json.dump(out, sys.stdout, indent=2)
    print()


def main():
    parser = argparse.ArgumentParser(prog="session-scan.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("baseline", help="extrae el catalogo first-party del harness")
    p.add_argument("--harness", required=True, help="ruta a dsh-session/lib/index.js")
    p.add_argument("--known", default=None, help="baseline vendorizado, para comparar")
    p.set_defaults(func=cmd_baseline)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: PASS — 3 tests verdes.

- [ ] **Step 5: Generar el baseline vendorizado desde el harness real**

```bash
cd /opt/dsh-manage
python3 plugins/session-scan.py baseline \
  --harness "$HOME/.local/dsh-node/node24/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); json.dump({"types": d["types"], "harnessVersion": "0.1.1-rc.2"}, open("plugins/known-session-event-types.json","w"), indent=2)'
python3 -c 'import json; print("tipos vendorizados:", len(json.load(open("plugins/known-session-event-types.json"))["types"]))'
```
Expected: `tipos vendorizados: 48`

- [ ] **Step 6: Commit**

```bash
git add plugins/session-scan.py plugins/known-session-event-types.json tests/session-backup.bats
git commit -m "feat(session-backup): baseline de tipos de evento con vendorizado de comparacion"
```

---

### Task 2: Lectura de logs, vocabulario y clasificación

**Files:**
- Modify: `plugins/session-scan.py`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `load_baseline()` de la Task 1.
- Produces: CLI `session-scan.py scan --sessions <dir> --harness <ruta> [--profile-node-modules <dir>] [--fail-on-risk]` → JSON `{"sessions":[{"id","directory","workspace","cwd","createdAt","artifact","events","risk","torn","unknownTypes":[{"type","count","owner"}]}],"baseline":[…],"owners":{…},"baselineCount":N}`. `createdAt` (del header, cuando existe) lo consume Task 4 para el `MANIFEST.json` del snapshot.
  **`directory` es el nombre real del directorio enumerado** — nunca se deriva de `id`.
  Códigos: 0 todo ok; con `--fail-on-risk`, 3 si hay `at-risk`, 4 si hay `broken`.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
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
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — el subcomando `scan` no existe.

- [ ] **Step 3: Escribir la implementación**

Agregar a `plugins/session-scan.py`, antes de `main()`:

```python
# Tags de FILA DE ALMACENAMIENTO, no de evento. El backend jsonl empaqueta
# rafagas de chunks con packChunkRuns y las expande con decodeStorageRecord a
# eventos `assistant/chunk` ANTES del chequeo de tipos. Si se cuentan como
# eventos, una sesion sana se clasifica como rota (paso: 60 de 71 falsos).
CHUNK_ROW_TAGS = {"text-chunks", "reasoning-chunks", "tool-call-chunks"}

# El tipo al que expanden las filas de chunk (esta en el baseline first-party).
CHUNK_EVENT_TYPE = "assistant/chunk"

# Vocabulario: solo literales que el plugin realmente PERSISTE via append(...).
# Un regex laxo tambien capturaria los de ctx.on(...) y produce duenos falsos.
APPEND_LITERAL = re.compile(r'append\(\s*"([a-z][a-z0-9-]*/[a-z0-9/-]+)"')
VOCAB_MARKER = "KNOWN_SESSION_EVENT_TYPES"
NODE_MODULES_SKIP = {".bin", ".pnpm", ".pnpm_patches", ".modules.yaml"}


def decode_storage_row(row):
    """Expande una fila de almacenamiento a sus eventos; el resto pasa igual.

    Espeja `decodeStorageRecord` del harness: solo los tres tags de chunk son
    filas. Para clasificar alcanza con el `type` resultante y la cantidad.
    """
    if row.get("type") not in CHUNK_ROW_TAGS:
        return [row]
    data = row.get("data") or {}
    members = data.get("args") if row["type"] == "tool-call-chunks" else data.get("texts")
    count = len(members) if isinstance(members, list) else 0
    return [{"type": CHUNK_EVENT_TYPE} for _ in range(count)]


def read_session_events(artifact):
    """Devuelve (header, eventos, torn) de un log .zstd o .jsonl plano.

    No usa check=True a proposito: un log con cola rota sale rc!=0 pero emite
    los datos validos, y el spec (§5.2) dice que sigue siendo restaurable.
    """
    torn = False
    if artifact.endswith(".zstd"):
        proc = subprocess.run(["zstd", "-dc", artifact], capture_output=True)
        raw = proc.stdout.decode("utf-8", errors="replace")
        torn = proc.returncode != 0
    else:
        with open(artifact, encoding="utf-8", errors="replace") as f:
            raw = f.read()
    header, events = None, []
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            torn = True   # cola rota a mitad de linea
            continue
        if header is None and row.get("type") == "session":
            header = row
            continue
        events.extend(decode_storage_row(row))
    return header, events, torn


def _scan_pkg(pkg_dir, owners):
    """Registra el vocabulario que declara un paquete, si lo declara."""
    lib = os.path.join(pkg_dir, "lib")
    manifest = os.path.join(pkg_dir, "package.json")
    if not (os.path.isdir(lib) and os.path.isfile(manifest)):
        return
    try:
        with open(manifest, encoding="utf-8") as f:
            meta = json.load(f)
        label = f"{meta['name']}@{meta.get('version', '?')}"
    except (OSError, ValueError, KeyError):
        return
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
            for kind in APPEND_LITERAL.findall(src):
                owners.setdefault(kind, label)


def scan_plugin_vocabulary(node_modules):
    """Mapa tipo -> "paquete@version" de los plugins que registran vocabulario.

    Itera el primer nivel de node_modules (mas un nivel por cada @scope). El
    plugin que importa aca vive top-level (`node_modules/dsh-swarm-panel`), asi
    que cualquier filtro que saltee ese nivel deja el mapa vacio.
    """
    owners = {}
    if not node_modules or not os.path.isdir(node_modules):
        return owners
    for entry in os.scandir(node_modules):
        if not entry.is_dir() or entry.name in NODE_MODULES_SKIP:
            continue
        if entry.name.startswith("@"):
            for sub in os.scandir(entry.path):
                if sub.is_dir():
                    _scan_pkg(sub.path, owners)
        else:
            _scan_pkg(entry.path, owners)
    return owners


def classify_session(workspace, directory, session_dir, baseline, owners):
    """Clasifica una sesion en ok / at-risk / broken / unsupported-version / unreadable."""
    artifact = None
    for name in ("session.jsonl.zstd", "session.jsonl"):
        candidate = os.path.join(session_dir, name)
        if os.path.isfile(candidate):
            artifact = candidate
            break
    if artifact is None:
        return None

    base = {"workspace": workspace, "directory": directory,
            "artifact": os.path.basename(artifact)}
    try:
        header, events, torn = read_session_events(artifact)
    except OSError:
        return {**base, "id": directory, "risk": "unreadable",
                "events": 0, "torn": True, "unknownTypes": []}
    if header is None:
        return {**base, "id": directory, "risk": "unreadable",
                "events": len(events), "torn": torn, "unknownTypes": []}
    if header.get("version") != 0:
        return {**base, "id": header.get("id", directory),
                "risk": "unsupported-version", "events": len(events),
                "torn": torn, "unknownTypes": []}

    counts = {}
    for event in events:
        kind = event.get("type")
        # Contrato estricto del harness: solo el booleano true salva al evento.
        if kind in baseline or event.get("ignorable") is True:
            continue
        counts[kind] = counts.get(kind, 0) + 1

    unknown = [{"type": k, "count": v, "owner": owners.get(k)}
               for k, v in sorted(counts.items())]
    if not unknown:
        risk = "ok"
    elif all(item["owner"] for item in unknown):
        risk = "at-risk"
    else:
        risk = "broken"
    return {**base, "id": header.get("id", directory), "cwd": header.get("cwd"),
            "createdAt": header.get("createdAt"), "events": len(events),
            "risk": risk, "torn": torn, "unknownTypes": unknown}


def cmd_scan(args):
    baseline = load_baseline(args.harness)
    owners = scan_plugin_vocabulary(args.profile_node_modules)
    results = []
    if os.path.isdir(args.sessions):
        for workspace in sorted(os.listdir(args.sessions)):
            ws_dir = os.path.join(args.sessions, workspace)
            if not os.path.isdir(ws_dir):
                continue
            for directory in sorted(os.listdir(ws_dir)):
                session_dir = os.path.join(ws_dir, directory)
                if not os.path.isdir(session_dir):
                    continue
                info = classify_session(workspace, directory, session_dir, baseline, owners)
                if info is not None:
                    results.append(info)
    json.dump({"sessions": results, "baseline": sorted(baseline),
               "owners": owners, "baselineCount": len(baseline)},
              sys.stdout, indent=2)
    print()
    if args.fail_on_risk:
        if any(r["risk"] == "broken" for r in results):
            sys.exit(4)
        if any(r["risk"] == "at-risk" for r in results):
            sys.exit(3)
```

Y registrar el subcomando en `main()`, después del parser de `baseline`:

```python
    p = sub.add_parser("scan", help="clasifica las sesiones por riesgo")
    p.add_argument("--sessions", required=True, help="ruta a $DSH_HOME/sessions")
    p.add_argument("--harness", required=True, help="ruta a dsh-session/lib/index.js")
    p.add_argument("--profile-node-modules", default=None,
                   help="node_modules del profile, para mapear tipo -> plugin")
    p.add_argument("--fail-on-risk", action="store_true",
                   help="sale 3 si hay at-risk, 4 si hay broken")
    p.set_defaults(func=cmd_scan)
```

- [ ] **Step 4: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: PASS — 12 tests verdes.

- [ ] **Step 5: Verificar contra el host real**

```bash
cd /opt/dsh-manage
python3 plugins/session-scan.py scan \
  --sessions "$HOME/.dsh/sessions" \
  --harness "$HOME/.local/dsh-node/node24/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js" \
  --profile-node-modules "$HOME/.dsh/profiles/web/node_modules" \
  | python3 - <<'PY'
import json, sys
d = json.load(sys.stdin)
rows = d["sessions"]
no_ok = [r for r in rows if r["risk"] != "ok"]
print("sesiones:", len(rows), "| no-ok:", len(no_ok), "| tipos con dueno:", len(d["owners"]))
for r in no_ok:
    print(" ", r["risk"], r["workspace"], r["directory"],
          sorted({u["owner"] or "sin dueno" for u in r["unknownTypes"]}))
PY
```
Expected (medido hoy; los números pueden variar si cambia el corpus): **no-ok cercano a 5, no a 60**, y `tipos con dueno: 14` — todos de `dsh-swarm-panel@0.1.0`. Si `tipos con dueno` sale 0, el escaneo de vocabulario está roto. Si no-ok sale ~60, la decodificación de filas de chunk está rota.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-scan.py tests/session-backup.bats
git commit -m "feat(session-backup): lectura con decodificacion de filas, vocabulario y clasificacion"
```

---

### Task 3: Subcomando `session-backup scan`

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session-scan.py scan` de la Task 2; `$DSH_MANAGE_DIR`, `$DSH_HOME`, `$DSH_NODE`, `$DSH_PREFIX`, `$DSH_PKG` (ya existen en el script).
- Produces: `dsh_session_lib_path()`, `session_backup_preflight()`, `session_backup_scan()`, `session_backup()` (despachador).

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
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
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `session-backup` no está en el dispatcher.

- [ ] **Step 3: Escribir la implementación**

En `dsh-manage.sh`, insertar **inmediatamente antes de la línea `update() {`**:

```bash
# Raiz de snapshots: HERMANA de sessions/, nunca hija — todo lo que cuelga de
# sessions/ es candidato a que el backend lo enumere como una sesion mas.
DSH_BACKUP_ROOT="${DSH_BACKUP_ROOT:-$DSH_HOME/session-backups}"

# Ruta al index.js de @deepseek-ai/dsh-session dentro del harness instalado.
# De ahi sale el baseline de tipos de evento; nunca se hardcodea la lista.
dsh_session_lib_path() {
  echo "$DSH_PREFIX/lib/node_modules/$DSH_PKG/node_modules/@deepseek-ai/dsh-session/lib/index.js"
}

# Preflight: herramientas, harness legible y backup root fuera de sessions/.
session_backup_preflight() {
  local missing=() tool
  for tool in python3 zstd sha256sum flock; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "faltan herramientas requeridas: ${missing[*]}" >&2
    return 1
  fi
  local lib
  lib="$(dsh_session_lib_path)"
  if [ ! -f "$lib" ]; then
    echo "no se encontro el harness en $lib — ¿esta dsh instalado?" >&2
    return 1
  fi
  # Invariante #1 del spec: los snapshots nunca pueden vivir bajo sessions/.
  case "$DSH_BACKUP_ROOT/" in
    "$DSH_HOME/sessions/"*)
      echo "DSH_BACKUP_ROOT no puede estar dentro de $DSH_HOME/sessions" >&2
      return 1 ;;
  esac
}

# scan: clasifica las sesiones por riesgo. SOLO LECTURA sobre sessions/.
session_backup_scan() {
  local profile="web" fail_on_risk=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        [ $# -ge 2 ] || { echo "falta el valor de --profile" >&2; return 1; }
        profile="$2"; shift 2 ;;
      --fail-on-risk) fail_on_risk=1; shift ;;
      *) echo "opcion desconocida para scan: $1" >&2; return 1 ;;
    esac
  done

  session_backup_preflight || return 1
  local sessions_dir="$DSH_HOME/sessions"
  if [ ! -d "$sessions_dir" ]; then
    echo "0 sesiones ($sessions_dir no existe)"
    return 0
  fi

  local args=(
    "$DSH_MANAGE_DIR/plugins/session-scan.py" scan
    --sessions "$sessions_dir"
    --harness "$(dsh_session_lib_path)"
  )
  local profile_nm="$DSH_HOME/profiles/$profile/node_modules"
  [ -d "$profile_nm" ] && args+=(--profile-node-modules "$profile_nm")
  [ "$fail_on_risk" -eq 1 ] && args+=(--fail-on-risk)

  local out rc=0
  out="$(python3 "${args[@]}")" || rc=$?
  if [ -z "$out" ]; then
    echo "el escaneo no devolvio datos" >&2
    return 1
  fi
  # El JSON va por argv: el heredoc ya ocupa stdin.
  python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
rows = d["sessions"]
if not rows:
    print("0 sesiones encontradas")
    sys.exit(0)
print(f'{"workspace":30} {"sesion":26} {"eventos":>8}  {"riesgo":10} dueno')
for r in rows:
    unknown = r.get("unknownTypes", [])
    if unknown:
        total = sum(u["count"] for u in unknown)
        owners = sorted({u["owner"] or "sin dueno" for u in unknown})
        detalle = f'{", ".join(owners)} ({total} ev. en {len(unknown)} tipos)'
    else:
        detalle = "-"
    print(f'{r["workspace"][:30]:30} {r["directory"][:26]:26} {r["events"]:>8}  {r["risk"]:10} {detalle}')
riesgo = [r for r in rows if r["risk"] != "ok"]
print()
if riesgo:
    print(f'{len(riesgo)} de {len(rows)} sesiones no-ok.')
    print('   → dsh-manage session-backup create --only-at-risk --label pre-cambios')
else:
    print(f'{len(rows)} sesiones, todas ok.')
PY
  return $rc
}

# Despachador de los subcomandos de session-backup.
session_backup() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    scan)     session_backup_scan "$@" ;;
    *) echo "uso: $0 session-backup {scan}"; return 1 ;;
  esac
}
```

En el `case` del dispatcher, insertar **antes de la línea `  version)          version ;;`**:

```bash
  session-backup)   session_backup "${@:2}" ;;
```

Y actualizar la línea de uso final agregando `session-backup {scan}` a la lista de comandos.

- [ ] **Step 4: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 5: Verificar contra el host real**

Run: `cd /opt/dsh-manage && ./dsh-manage.sh session-backup scan`
Expected: tabla con las sesiones, **sin `Traceback` ni `SyntaxError`**, y un resumen final del estilo `N de 71 sesiones no-ok`.

- [ ] **Step 6: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): subcomando scan"
```

---

### Task 4: Subcomandos `create`, `list` y `verify`

**Files:**
- Modify: `dsh-manage.sh`
- Modify: `plugins/session-scan.py`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_preflight()` y `dsh_session_lib_path()` de la Task 3; el campo `sessions[].directory` de la Task 2.
- Produces: `session_backup_create/list/verify()` en bash; CLI interna `session-scan.py snapshot --scan-json <ruta> --snap-dir <ruta> --sessions <dir>`; snapshot en `$DSH_BACKUP_ROOT/<UTC>-<label>/` con `MANIFEST.json`, `CHECKSUMS.sha256`, `vocabulary.json`, `scan.json` y `sessions/<workspace>/<directory>/<artifact>`.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
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
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `create` no es un subcomando válido.

- [ ] **Step 3: Agregar `cmd_snapshot` al helper Python**

Agregar a `plugins/session-scan.py`, antes de `main()`:

```python
import hashlib
import shutil
from datetime import datetime, timezone


def cmd_snapshot(args):
    """Copia los artefactos y escribe MANIFEST.json, CHECKSUMS.sha256 y
    vocabulary.json. Copia, nunca mueve: el original se abre solo en lectura.

    Falla si la cantidad copiada no coincide con la esperada: un snapshot
    parcial publicado como completo da falsa seguridad.
    """
    snap, sessions_dir = args.snap_dir, args.sessions
    only_at_risk = os.environ.get("DSH_ONLY_AT_RISK") == "1"
    with open(args.scan_json, encoding="utf-8") as f:
        scan = json.load(f)

    esperadas = [r for r in scan["sessions"]
                 if not (only_at_risk and r["risk"] == "ok")]
    entries, checksums, faltantes = [], [], []

    for row in esperadas:
        # `directory` viene del enumerado real del scan: nunca se deriva del id.
        rel = os.path.join("sessions", row["workspace"], row["directory"], row["artifact"])
        src = os.path.join(sessions_dir, row["workspace"], row["directory"], row["artifact"])
        if not os.path.isfile(src):
            faltantes.append(rel)
            continue
        dst = os.path.join(snap, rel)
        os.makedirs(os.path.dirname(dst), mode=0o700, exist_ok=True)
        try:
            shutil.copy(src, dst)          # copy, no copy2: no arrastra permisos del origen
            os.chmod(dst, 0o600)
        except OSError as exc:
            faltantes.append(f"{rel} ({exc})")
            continue
        digest = hashlib.sha256()
        with open(dst, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                digest.update(chunk)
        checksums.append(f"{digest.hexdigest()}  {rel}")
        entries.append({**row, "sha256": digest.hexdigest(),
                        "bytes": os.path.getsize(dst)})

    if faltantes:
        raise SystemExit(
            "no se pudieron copiar {} de {} sesiones esperadas:\n  {}".format(
                len(faltantes), len(esperadas), "\n  ".join(faltantes)))

    if not entries:
        # Sin nada que respaldar: no se publica un snapshot vacio.
        raise SystemExit(2)

    manifest = {
        "schemaVersion": 1,
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "label": os.environ.get("DSH_LABEL", "manual"),
        "trigger": os.environ.get("DSH_TRIGGER", "manual"),
        "dshManageVersion": os.environ.get("DSH_MANAGE_VERSION", "?"),
        "dshHome": os.path.dirname(sessions_dir),
        "profile": os.environ.get("DSH_PROFILE", "web"),
        "sessionFormatVersion": 0,
        "sessions": entries,
    }
    with open(os.path.join(snap, "MANIFEST.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    # vocabulary.json: la receta de QUE reinstalar para volver a leer esto.
    # Es dato perecedero — solo `create` esta en posicion de congelarlo.
    with open(os.path.join(snap, "vocabulary.json"), "w", encoding="utf-8") as f:
        json.dump({"baseline": scan["baseline"], "owners": scan["owners"],
                   "baselineCount": scan["baselineCount"]}, f, indent=2)

    for extra in ("MANIFEST.json", "vocabulary.json", "scan.json"):
        path = os.path.join(snap, extra)
        if not os.path.isfile(path):
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                digest.update(chunk)
        checksums.append(f"{digest.hexdigest()}  {extra}")

    with open(os.path.join(snap, "CHECKSUMS.sha256"), "w", encoding="utf-8") as f:
        f.write("\n".join(checksums) + "\n")
    print(f"{len(entries)} sesiones copiadas")
```

y su registro en `main()`:

```python
    p = sub.add_parser("snapshot", help="copia artefactos y escribe manifest (uso interno)")
    p.add_argument("--scan-json", required=True)
    p.add_argument("--snap-dir", required=True)
    p.add_argument("--sessions", required=True)
    p.set_defaults(func=cmd_snapshot)
```

- [ ] **Step 4: Agregar los subcomandos bash**

En `dsh-manage.sh`, después de `session_backup_scan()`:

```bash
# create: snapshot atomico. Construye en <nombre>.partial/ y renombra al final
# — un directorio con nombre final es, por invariante, un snapshot completo.
# Ante fallo el .partial SE CONSERVA (spec §5.1): es la evidencia de que se
# alcanzo a copiar, y borrarlo abria un vector de traversal via --label.
session_backup_create() {
  local label="manual" only_at_risk=0 profile="web"
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)
        [ $# -ge 2 ] || { echo "falta el valor de --label" >&2; return 1; }
        label="$2"; shift 2 ;;
      --profile)
        [ $# -ge 2 ] || { echo "falta el valor de --profile" >&2; return 1; }
        profile="$2"; shift 2 ;;
      --only-at-risk) only_at_risk=1; shift ;;
      *) echo "opcion desconocida para create: $1" >&2; return 1 ;;
    esac
  done

  # El label entra en una ruta: sin validar, '../../x' escapa del backup root.
  if ! printf '%s' "$label" | grep -qE '^[A-Za-z0-9._-]+$'; then
    echo "label invalido: solo se permiten [A-Za-z0-9._-]" >&2
    return 1
  fi

  session_backup_preflight || return 1
  umask 077
  local sessions_dir="$DSH_HOME/sessions"
  if [ ! -d "$sessions_dir" ]; then
    echo "nada que respaldar ($sessions_dir no existe)"
    return 2
  fi

  mkdir -p "$DSH_BACKUP_ROOT"
  local stamp snap partial
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  snap="$DSH_BACKUP_ROOT/${stamp}-${label}"
  partial="${snap}.partial"
  if [ -e "$snap" ] || [ -e "$partial" ]; then
    echo "ya existe un snapshot con ese nombre: $snap" >&2
    return 1
  fi
  mkdir -p "$partial/sessions"

  # Lock: dos colegas corriendo create en paralelo no se pisan. El subshell
  # cierra el fd al salir, sin dejarlo colgado en el proceso.
  (
    flock -w 30 9 || { echo "otro session-backup esta corriendo" >&2; exit 1; }

    local scan_args=(
      "$DSH_MANAGE_DIR/plugins/session-scan.py" scan
      --sessions "$sessions_dir"
      --harness "$(dsh_session_lib_path)"
    )
    local profile_nm="$DSH_HOME/profiles/$profile/node_modules"
    [ -d "$profile_nm" ] && scan_args+=(--profile-node-modules "$profile_nm")
    python3 "${scan_args[@]}" > "$partial/scan.json" || exit 1

    DSH_LABEL="$label" DSH_ONLY_AT_RISK="$only_at_risk" DSH_PROFILE="$profile" \
    DSH_MANAGE_VERSION="$DSH_MANAGE_VERSION" \
    python3 "$DSH_MANAGE_DIR/plugins/session-scan.py" snapshot \
      --scan-json "$partial/scan.json" --snap-dir "$partial" --sessions "$sessions_dir" \
      || exit $?
  ) 9>"$DSH_BACKUP_ROOT/.lock"
  local rc=$?

  if [ "$rc" -eq 2 ]; then
    rmdir "$partial/sessions" "$partial" 2>/dev/null || true
    echo "nada que respaldar (ninguna sesion coincide con el filtro)"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    echo "fallo la creacion del snapshot; se conserva $partial para inspeccion" >&2
    return 1
  fi

  session_backup_verify_dir "$partial" || {
    echo "el snapshot no valida; se conserva $partial para inspeccion" >&2
    return 1
  }

  mv -T "$partial" "$snap"
  ln -sfn "$(basename "$snap")" "$DSH_BACKUP_ROOT/.latest.tmp"
  mv -T "$DSH_BACKUP_ROOT/.latest.tmp" "$DSH_BACKUP_ROOT/latest"
  echo "snapshot creado: $snap"
}

# Validacion completa de un snapshot: checksums + zstd -t + header parseable.
# La comparten `create` (antes de publicar) y `verify`.
session_backup_verify_dir() {
  local snap="$1"
  [ -s "$snap/CHECKSUMS.sha256" ] || { echo "CHECKSUMS.sha256 ausente o vacio" >&2; return 1; }
  ( cd "$snap" && sha256sum -c CHECKSUMS.sha256 >/dev/null ) \
    || { echo "checksums no verifican en $snap" >&2; return 1; }
  local artifact
  while IFS= read -r artifact; do
    case "$artifact" in
      *.zstd)
        zstd -t "$artifact" >/dev/null 2>&1 \
          || { echo "zstd corrupto: $artifact" >&2; return 1; }
        zstd -dc "$artifact" 2>/dev/null | head -1 | python3 -c '
import json, sys
line = sys.stdin.readline()
row = json.loads(line)
assert row.get("type") == "session", row.get("type")
' >/dev/null 2>&1 || { echo "header ilegible: $artifact" >&2; return 1; } ;;
      *.jsonl)
        head -1 "$artifact" | python3 -c '
import json, sys
row = json.loads(sys.stdin.readline())
assert row.get("type") == "session", row.get("type")
' >/dev/null 2>&1 || { echo "header ilegible: $artifact" >&2; return 1; } ;;
    esac
  done < <(find "$snap/sessions" -type f 2>/dev/null)
  return 0
}

# list: snapshots completos (los .partial se ignoran por invariante).
session_backup_list() {
  if [ ! -d "$DSH_BACKUP_ROOT" ]; then
    echo "no hay snapshots ($DSH_BACKUP_ROOT no existe)"
    return 0
  fi
  local found=0 partials=0 dir
  for dir in "$DSH_BACKUP_ROOT"/*/; do
    [ -d "$dir" ] || continue
    case "$dir" in *.partial/) partials=$((partials + 1)); continue ;; esac
    [ -f "${dir}MANIFEST.json" ] || continue
    found=$((found + 1))
    python3 - "${dir}MANIFEST.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(f'{m["createdAt"]}  {m["label"]:28} {len(m["sessions"]):>3} sesiones  ({m.get("trigger","manual")})')
PY
  done
  [ "$found" -eq 0 ] && echo "no hay snapshots completos"
  [ "$partials" -gt 0 ] && \
    echo "aviso: hay $partials snapshot(s) .partial de intentos fallidos; borrables a mano"
  return 0
}

# verify: integridad de un snapshot ya publicado.
session_backup_verify() {
  local from="latest"
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        [ $# -ge 2 ] || { echo "falta el valor de --from" >&2; return 1; }
        from="$2"; shift 2 ;;
      *) echo "opcion desconocida para verify: $1" >&2; return 1 ;;
    esac
  done
  local snap="$DSH_BACKUP_ROOT/$from"
  [ -d "$snap" ] || { echo "snapshot no encontrado: $snap" >&2; return 1; }
  session_backup_verify_dir "$snap" || return 1
  echo "OK — $snap integro"
}
```

Ampliar el despachador `session_backup()`:

```bash
    create)   session_backup_create "$@" ;;
    list)     session_backup_list "$@" ;;
    verify)   session_backup_verify "$@" ;;
```
y su línea de uso a `{scan|create|list|verify}`.

- [ ] **Step 5: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS — 20 tests verdes + shellcheck limpio.

- [ ] **Step 6: Verificar contra el host real**

```bash
cd /opt/dsh-manage
marker="$(mktemp)"
./dsh-manage.sh session-backup create --label verificacion
./dsh-manage.sh session-backup verify --from latest
find "$HOME/.dsh/sessions" -type f -newer "$marker" -print
```
Expected: `snapshot creado: …`, luego `OK — … integro`, y el `find` **sin ninguna salida** (nada nuevo bajo `sessions/`).

- [ ] **Step 7: Commit**

```bash
git add dsh-manage.sh plugins/session-scan.py tests/session-backup.bats
git commit -m "feat(session-backup): subcomandos create, list y verify"
```

---

### Task 5: Documentar el hallazgo del harness en el manifest

**Files:**
- Modify: `plugins/manifest.json`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Produces: clave `sessionEventWriters` en el manifest.

> **Nota:** la v1 de este plan tenía acá un patch a `dsh-swarm-panel` para que emitiera `ignorable: true`. Se eliminó: `Session.append()` de `dsh-session@0.1.1-rc.2` **descarta** ese flag (verificado en `lib/index.js:1444`), así que el patch habría reiniciado producción a cambio de nada. Lo que queda es dejar el hallazgo escrito donde el próximo colega lo encuentre.

- [ ] **Step 1: Escribir el test que falla**

Agregar a `tests/session-backup.bats`:

```bash
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
```

- [ ] **Step 2: Correr el test para ver que falla**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — no existe la clave `sessionEventWriters`.

- [ ] **Step 3: Agregar la clave al manifest**

En `plugins/manifest.json`, agregar una clave nueva de primer nivel (después de `patchNotes`):

```json
"sessionEventWriters": {
  "dsh-swarm-panel": {
    "prefixes": ["swarm/"],
    "installedVersion": "0.1.0",
    "note": "Registra su vocabulario en KNOWN_SESSION_EVENT_TYPES como efecto de ciclo de vida: al descargarlo, las sesiones con eventos swarm/* dejan de cargar (SessionFormatUnsupportedError). NO se puede arreglar parcheando el plugin: Session.append() de dsh-session 0.1.1-rc.2 descarta el flag ignorable (lib/index.js:1444, arma el envelope solo con sourceEventSeqs y surfaceOp). El fix es del harness y hoy existe unicamente en master, sin acompanar ninguna rc publicada. Hasta entonces el camino es: backup antes de desinstalar, y reinstalar el plugin para volver a leer esas sesiones."
  }
}
```

- [ ] **Step 4: Correr los tests**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: PASS — 21 tests verdes.

- [ ] **Step 5: Commit**

```bash
git add plugins/manifest.json tests/session-backup.bats
git commit -m "docs(manifest): declarar dsh-swarm-panel como event writer y el limite del harness"
```

---

### Task 6: Versión y documentación

**Files:**
- Modify: `dsh-manage.sh` (línea 42), `CHANGELOG.md`, `README.md`
- Test: `tests/dsh-manage.bats`

- [ ] **Step 1: Bump de versión con su test**

En `dsh-manage.sh` línea 42, cambiar `DSH_MANAGE_VERSION="1.1.0"` por:

```bash
DSH_MANAGE_VERSION="1.2.0"
```

Agregar a `tests/session-backup.bats`:

```bash
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
```

- [ ] **Step 2: Correr los tests**

Run: `cd /opt/dsh-manage && bats tests/`
Expected: PASS — incluidos los tests previos de `--version` en `tests/dsh-manage.bats`.

- [ ] **Step 3: CHANGELOG**

Insertar **inmediatamente antes de la línea `## [1.1.0] - 2026-08-24`**:

```markdown
## [Unreleased]

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
```

- [ ] **Step 4: README**

Agregar a la tabla de comandos, después de la fila de `service-install`:

```markdown
| `session-backup {scan,create,list,verify}` | Resguardo de sesiones: clasifica riesgo y crea snapshots verificables |
```

Insertar una sección nueva **inmediatamente después de la sección `### service-install`** (línea 137) y **antes de `## Requisitos`** (línea 151):

````markdown
### `session-backup`: resguardo de sesiones

Algunos plugins (`dsh-swarm-panel` y otros *event-writers*) registran tipos de
evento propios en el harness **mientras están cargados**. Si se desinstalan, las
sesiones que usaron esos eventos dejan de cargar
(`SessionFormatUnsupportedError`). Pasó de verdad en este proyecto.

```bash
dsh-manage session-backup scan       # ¿qué sesiones están en riesgo?
dsh-manage session-backup create --only-at-risk --label pre-cambios
dsh-manage session-backup list
dsh-manage session-backup verify --from latest
```

| Clase | Significado |
|---|---|
| `ok` | Solo tipos first-party. Inmune a instalar/desinstalar plugins. |
| `at-risk` | Tiene tipos de un plugin **instalado**. Carga hoy; se rompe si lo desinstalás. |
| `broken` | Tiene tipos que ningún plugin instalado declara. Ya no carga. |

`scan`, `create`, `list` y `verify` **nunca escriben bajo `sessions/`**. Los
snapshots viven en `$DSH_HOME/session-backups/` (hermano de `sessions/`), con
`MANIFEST.json`, `CHECKSUMS.sha256` y `vocabulary.json` — verificables con
`sha256sum -c` sin necesitar este script.

> ⚠️ **Esto da visibilidad y copias, no inmunidad.** Nada impide todavía un
> `plugin remove` que rompa sesiones (eso es la Fase 4 del diseño), y los eventos
> ya escritos siguen sin marcar porque **el harness `0.1.1-rc.2` descarta el flag
> `ignorable`** — no es algo que se arregle desde un plugin. Hasta que salga una
> release del harness que lo propague, la recuperación de una sesión rota es:
> reinstalar el plugin que declaraba esos tipos.

> ⚠️ **Si restaurás un log a mano con `cp`, detené DSH primero**
> (`systemctl stop dsh.service`). El proceso vivo mantiene un descriptor abierto
> en modo append: reemplazar el archivo por debajo hace que la restauración se
> pierda en silencio.
````

Agregar a la tabla de variables de entorno:

```markdown
| `DSH_BACKUP_ROOT`   | `$DSH_HOME/session-backups`            | Raíz de los snapshots de sesión           |
```

- [ ] **Step 5: Verificación final completa**

Run: `cd /opt/dsh-manage && make check && make bats`
Expected: shellcheck limpio y todos los tests verdes (los 33 previos + los nuevos).

- [ ] **Step 6: Commit**

```bash
git add dsh-manage.sh CHANGELOG.md README.md tests/session-backup.bats
git commit -m "docs(session-backup): documentar scan/create/list/verify + bump a 1.2.0"
```

---

## Self-Review

**1. Cobertura de los 15 bloqueantes del arbitraje**

| # | Bloqueante | Dónde se resuelve |
|---|---|---|
| 1 | Decodificar filas de chunk | Task 2 — `decode_storage_row()` + test dedicado |
| 2 | Eliminar el patch del plugin | Task 5 reconvertida a documentación |
| 3 | Quitar el filtro que saltea top-level | Task 2 — `scan_plugin_vocabulary()` con `os.scandir` |
| 4 | Anclar el regex a `append("` | Task 2 — `APPEND_LITERAL` + test de `ctx.on` |
| 5 | Python embebido sin `\"` | Tasks 3 y 4 — heredoc + datos por `argv` |
| 6 | `fake_harness` en la ruta del preflight | Task 1 — `install_fake_harness()` |
| 7 | `sessions[].directory` y borrar `_dir_of` | Task 2 (lo emite) + Task 4 (lo consume) |
| 8 | No abortar con CHECKSUMS vacío | Task 4 — `SystemExit(2)` + salida 2 en bash |
| 9 | Parsear `--profile` en `scan` | Task 3 — bucle de flags + 2 tests |
| 10 | Conservar `.partial` + validar label | Task 4 — sin `rm -rf`, `grep -qE` sobre el label |
| 11 | `vocabulary.json` en el snapshot | Task 4 — `cmd_snapshot` + assert en test |
| 12 | Capturar stdout de `zstd` con rc≠0 | Task 2 — `read_session_events` sin `check=True` |
| 13 | Fallar si copiadas ≠ esperadas | Task 4 — lista `faltantes` + `SystemExit` |
| 14 | `[Unreleased]` + bump a 1.2.0 | Task 6 + test del manifest |
| 15 | Expected sobre fixtures | Tasks 2-4; el paso contra el host real es orientativo |

**2. Cobertura de las 9 mejoras**: 16 (README con "DSH detenido") Task 6 ✅; 17 (fd del lock) Task 4, subshell `9>` ✅; 18 (invariante por sha256+metadata) Task 4 ✅; 19 (rechazar `DSH_BACKUP_ROOT` bajo `sessions/`) Task 3, preflight ✅; 20 (baseline vendorizado) Task 1 ✅; 21 (test `.partial` con snapshot válido) Task 4 ✅; 23 (`zstd -t` + header antes de publicar) Task 4, `session_backup_verify_dir` ✅; 24 (`list` avisa de `.partial`) Task 4 ✅. **Postergada**: 22 (lectura estable de logs vivos) — declarada en "Interfaz incluida", va con `--include-live` en Fase 3.

**3. Placeholders**: ninguno. Todo paso tiene el código o el comando exacto. El único Expected dependiente del host (Task 2 Step 5) está marcado como orientativo y con criterio de falla explícito.

**4. Consistencia de tipos**: `load_baseline()` (Task 1) → usada por `cmd_scan` (Task 2). El contrato `sessions[].{workspace,directory,id,artifact,events,risk,torn,unknownTypes}` se produce en Task 2 y se consume en Tasks 3-4 con esos nombres. `session_backup_verify_dir()` se define en Task 4 y la usan `create` y `verify`. `DSH_BACKUP_ROOT` se define en Task 3 y se usa en Task 4.
