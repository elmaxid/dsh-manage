# Session Backup (Fase 1+2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agregar `dsh-manage session-backup` con los subcomandos read-only y de snapshot (`scan`, `create`, `list`, `verify`), más un patch local que hace que `dsh-swarm-panel` emita `ignorable: true`.

**Architecture:** Un bloque de funciones nuevas en `dsh-manage.sh` (mismo estilo que `plugins_install`/`service_install`), más un helper Python para el trabajo pesado de JSON/zstd (mismo patrón que `plugins/merge-pnpm-workspace.py`). El baseline de tipos de evento se extrae parseando el harness instalado, nunca se hardcodea. Ninguna función de estas fases escribe bajo `$DSH_HOME/sessions/`.

**Tech Stack:** bash (`set -euo pipefail`), python3 + zstd/jq/sha256sum/flock, bats-core para tests, pnpm patch para el plugin.

**Spec:** `docs/SESSION-BACKUP-DESIGN.md` (fases 1 y 2 de §7, más la enmienda §7.2)

## Global Constraints

- Bash con `set -euo pipefail`; shellcheck debe pasar limpio (`make check`).
- Comentarios y salida al usuario en español, igual que el resto del script.
- **Ninguna función de este plan escribe bajo `$DSH_HOME/sessions/`.** Ni un `.bak`, ni un temp.
- `DSH_HOME` = config real de dsh (default `$HOME/.dsh`). `DSH_MANAGE_HOME` = dir de trabajo del script (default `$HOME/dsh-test`). No confundirlas.
- Backup root default: `$DSH_HOME/session-backups` — hermano de `sessions/`, nunca hijo.
- Permisos: `umask 077` al inicio de cada subcomando que escriba; directorios `0700`, archivos `0600`.
- Baseline verificado hoy: **48** tipos en `KNOWN_SESSION_EVENT_TYPES`. Piso de cordura: **20** (menos que eso = fallo duro).
- `ignorable` cuenta **solo** si es exactamente `true` (booleano). `null` y `"true"` NO cuentan.
- Ruta del harness para el baseline: `$DSH_NODE/../lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js`.
- Fases 3-5 (`restore`, `repair`, `prune`, integración con `plugins-remove`) están **fuera de alcance**. La enmienda §7.2 (invalidar `session_projcache.json`) pertenece al plan de Fase 3.

---

## File Structure

| Archivo | Responsabilidad |
|---|---|
| `plugins/session-scan.py` (crear) | Todo el trabajo pesado: parsear baseline, escanear vocabulario de plugins, leer logs zstd, clasificar riesgo. Emite JSON. |
| `dsh-manage.sh` (modificar) | Subcomandos `session-backup {scan,create,list,verify}` + dispatcher. Orquesta, no parsea JSON a mano. |
| `plugins/patches/dsh-swarm-panel@0.1.0.patch` (crear) | Patch local: el plugin emite `ignorable: true` en sus eventos. |
| `plugins/manifest.json` (modificar) | Registra el patch nuevo + clave `sessionEventWriters`. |
| `tests/session-backup.bats` (crear) | Tests de las funciones nuevas, con fixtures sintéticos. |
| `README.md`, `CHANGELOG.md` (modificar) | Documentación. |

---

### Task 1: Helper de scan — baseline y clasificación

**Files:**
- Create: `plugins/session-scan.py`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Produces: CLI `python3 plugins/session-scan.py baseline --harness <ruta-index.js>` → imprime JSON `{"types": [...], "count": N}` a stdout. Sale 1 si `count < 20`.

- [ ] **Step 1: Escribir el test que falla**

Crear `tests/session-backup.bats` con este contenido:

```bash
#!/usr/bin/env bats

# Tests de session-backup. Fixtures sinteticos: nunca se copian sesiones
# reales al repo (contienen prompts y rutas del host).

setup() {
  export DSH_MANAGE_HOME="$BATS_TEST_TMPDIR/home"
  export DSH_HOME="$BATS_TEST_TMPDIR/dsh-home"
  export DSH_NODE="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$DSH_MANAGE_HOME" "$DSH_HOME" "$DSH_NODE"
  SCAN="$BATS_TEST_DIRNAME/../plugins/session-scan.py"
}

# Crea un index.js falso del harness con N tipos de evento.
fake_harness() {
  local n="$1" dir="$BATS_TEST_TMPDIR/harness"
  mkdir -p "$dir"
  {
    printf 'const KNOWN_SESSION_EVENT_TYPES = new Set([\n'
    for ((i = 0; i < n; i++)); do printf '\t"tipo/%d",\n' "$i"; done
    printf ']);\n'
  } > "$dir/index.js"
  echo "$dir/index.js"
}

@test "baseline extrae los tipos del harness" {
  h="$(fake_harness 48)"
  run python3 "$SCAN" baseline --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"count": 48'* ]]
  [[ "$output" == *'tipo/0'* ]]
}

@test "baseline con menos de 20 tipos es fallo duro" {
  h="$(fake_harness 5)"
  run python3 "$SCAN" baseline --harness "$h"
  [ "$status" -ne 0 ]
  [[ "$output" == *"piso de cordura"* ]]
}
```

- [ ] **Step 2: Correr el test para ver que falla**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `session-scan.py` no existe.

- [ ] **Step 3: Escribir la implementación mínima**

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
import re
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


def cmd_baseline(args):
    types = extract_baseline(args.harness)
    if len(types) < BASELINE_FLOOR:
        raise SystemExit(
            f"baseline con solo {len(types)} tipos, por debajo del piso de cordura "
            f"({BASELINE_FLOOR}): el harness cambio de formato o el parseo fallo. "
            "Abortando para no clasificar todo como roto."
        )
    json.dump({"types": sorted(types), "count": len(types)}, sys.stdout, indent=2)
    print()


def main():
    parser = argparse.ArgumentParser(prog="session-scan.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("baseline", help="extrae el catalogo first-party del harness")
    p.add_argument("--harness", required=True, help="ruta a dsh-session/lib/index.js")
    p.set_defaults(func=cmd_baseline)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Correr el test para ver que pasa**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: PASS — 2 tests verdes.

- [ ] **Step 5: Verificar contra el harness real**

Run: `python3 plugins/session-scan.py baseline --harness "$HOME/.local/dsh-node/node24/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js" | tail -3`
Expected: `"count": 48`

- [ ] **Step 6: Commit**

```bash
git add plugins/session-scan.py tests/session-backup.bats
git commit -m "feat(session-backup): extraer baseline de tipos de evento del harness"
```

---

### Task 2: Escaneo de logs y clasificación de riesgo

**Files:**
- Modify: `plugins/session-scan.py`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `extract_baseline()` de la Task 1.
- Produces: CLI `python3 plugins/session-scan.py scan --sessions <dir> --harness <ruta> [--profile-node-modules <dir>]` → JSON `{"sessions":[{"id","workspace","cwd","events","risk","unknownTypes":[{"type","count","owner"}],"artifact"}]}`. Códigos: 0 todo ok, 3 hay `at-risk`, 4 hay `broken` (solo con `--fail-on-risk`).

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
# Crea una sesion sintetica comprimida. $1=dir sessions, $2=workspace,
# $3=session-id, $4..=lineas de evento JSON.
fake_session() {
  local root="$1" ws="$2" sid="$3"; shift 3
  local dir="$root/$ws/$sid"
  mkdir -p "$dir"
  {
    printf '{"type":"session","version":0,"id":"%s","createdAt":1,"cwd":"/tmp/%s"}\n' "$sid" "$ws"
    for line in "$@"; do printf '%s\n' "$line"; done
  } | zstd -q -o "$dir/session.jsonl.zstd"
}

@test "sesion con solo tipos del baseline es ok" {
  h="$(fake_harness 48)"
  s="$BATS_TEST_TMPDIR/sessions"
  fake_session "$s" "--tmp-a--" "session-aaa" \
    '{"type":"tipo/0","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$s" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "ok"'* ]]
}

@test "tipo desconocido sin dueno instalado es broken" {
  h="$(fake_harness 48)"
  s="$BATS_TEST_TMPDIR/sessions"
  fake_session "$s" "--tmp-b--" "session-bbb" \
    '{"type":"foo/bar","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$s" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "broken"'* ]]
}

@test "tipo desconocido con plugin que lo declara es at-risk" {
  h="$(fake_harness 48)"
  s="$BATS_TEST_TMPDIR/sessions"
  nm="$BATS_TEST_TMPDIR/nm/plugin-falso/lib"
  mkdir -p "$nm"
  cat > "$BATS_TEST_TMPDIR/nm/plugin-falso/package.json" <<'EOF'
{"name":"plugin-falso","version":"9.9.9"}
EOF
  cat > "$nm/index.js" <<'EOF'
import { KNOWN_SESSION_EVENT_TYPES } from "@deepseek-ai/dsh-session";
const SWARM_EVENT_TYPES = ["foo/bar"];
const known = KNOWN_SESSION_EVENT_TYPES;
EOF
  fake_session "$s" "--tmp-c--" "session-ccc" \
    '{"type":"foo/bar","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$s" --harness "$h" --profile-node-modules "$BATS_TEST_TMPDIR/nm"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "at-risk"'* ]]
  [[ "$output" == *"plugin-falso@9.9.9"* ]]
}

@test "ignorable true hace que el tipo desconocido no cuente" {
  h="$(fake_harness 48)"
  s="$BATS_TEST_TMPDIR/sessions"
  fake_session "$s" "--tmp-d--" "session-ddd" \
    '{"type":"foo/bar","seq":1,"time":1,"ignorable":true,"data":{}}'
  run python3 "$SCAN" scan --sessions "$s" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "ok"'* ]]
}

@test "ignorable null NO cuenta como ignorable (regresion vpn-monitor)" {
  h="$(fake_harness 48)"
  s="$BATS_TEST_TMPDIR/sessions"
  fake_session "$s" "--tmp-e--" "session-eee" \
    '{"type":"foo/bar","seq":1,"time":1,"ignorable":null,"data":{}}'
  run python3 "$SCAN" scan --sessions "$s" --harness "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"risk": "broken"'* ]]
}

@test "fail-on-risk sale 4 si hay broken" {
  h="$(fake_harness 48)"
  s="$BATS_TEST_TMPDIR/sessions"
  fake_session "$s" "--tmp-f--" "session-fff" \
    '{"type":"foo/bar","seq":1,"time":1,"data":{}}'
  run python3 "$SCAN" scan --sessions "$s" --harness "$h" --fail-on-risk
  [ "$status" -eq 4 ]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — el subcomando `scan` no existe.

- [ ] **Step 3: Escribir la implementación**

Agregar a `plugins/session-scan.py`, antes de `main()`:

```python
import os
import subprocess

# Patron de registro de vocabulario: un plugin importa KNOWN_SESSION_EVENT_TYPES
# y agrega sus tipos. Se buscan los literales "algo/algo" del mismo archivo.
VOCAB_MARKER = "KNOWN_SESSION_EVENT_TYPES"
EVENT_LITERAL = re.compile(r'"([a-z][a-z0-9-]*/[a-z0-9/-]+)"')


def scan_plugin_vocabulary(node_modules):
    """Mapa tipo -> "paquete@version" de los plugins que registran vocabulario.

    Escanea el node_modules REAL: es el unico lugar donde aparece un plugin
    instalado a mano (dsh-swarm-panel no esta en el manifest).
    """
    owners = {}
    if not node_modules or not os.path.isdir(node_modules):
        return owners
    for pkg_dir, _, _ in os.walk(node_modules):
        if os.path.basename(os.path.dirname(pkg_dir)) == "node_modules":
            continue
        lib = os.path.join(pkg_dir, "lib")
        manifest = os.path.join(pkg_dir, "package.json")
        if not (os.path.isdir(lib) and os.path.isfile(manifest)):
            continue
        try:
            with open(manifest, encoding="utf-8") as f:
                meta = json.load(f)
            label = f"{meta['name']}@{meta.get('version', '?')}"
        except (OSError, ValueError, KeyError):
            continue
        for entry in os.listdir(lib):
            if not entry.endswith(".js"):
                continue
            try:
                with open(os.path.join(lib, entry), encoding="utf-8", errors="replace") as f:
                    src = f.read()
            except OSError:
                continue
            if VOCAB_MARKER not in src:
                continue
            for kind in EVENT_LITERAL.findall(src):
                owners.setdefault(kind, label)
    return owners


def read_session_events(artifact):
    """Devuelve (header, [eventos]) de un log .zstd o .jsonl plano."""
    if artifact.endswith(".zstd"):
        raw = subprocess.run(
            ["zstd", "-dc", artifact], capture_output=True, check=True
        ).stdout.decode("utf-8", errors="replace")
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
            continue  # cola rota: el harness la tolera, nosotros tambien
        if header is None and row.get("type") == "session":
            header = row
            continue
        events.append(row)
    return header, events


def classify_session(session_dir, baseline, owners):
    """Clasifica una sesion en ok / at-risk / broken / unsupported-version / unreadable."""
    artifact = None
    for name in ("session.jsonl.zstd", "session.jsonl"):
        candidate = os.path.join(session_dir, name)
        if os.path.isfile(candidate):
            artifact = candidate
            break
    if artifact is None:
        return None
    try:
        header, events = read_session_events(artifact)
    except (subprocess.CalledProcessError, OSError):
        return {"id": os.path.basename(session_dir), "risk": "unreadable",
                "artifact": os.path.basename(artifact), "events": 0, "unknownTypes": []}
    if header is None:
        return {"id": os.path.basename(session_dir), "risk": "unreadable",
                "artifact": os.path.basename(artifact), "events": len(events),
                "unknownTypes": []}
    if header.get("version") != 0:
        return {"id": header.get("id", os.path.basename(session_dir)),
                "risk": "unsupported-version", "artifact": os.path.basename(artifact),
                "events": len(events), "unknownTypes": []}

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
    return {"id": header.get("id", os.path.basename(session_dir)),
            "cwd": header.get("cwd"), "createdAt": header.get("createdAt"),
            "artifact": os.path.basename(artifact), "events": len(events),
            "risk": risk, "unknownTypes": unknown}


def cmd_scan(args):
    baseline = set(extract_baseline(args.harness))
    if len(baseline) < BASELINE_FLOOR:
        raise SystemExit(
            f"baseline con solo {len(baseline)} tipos, por debajo del piso de cordura "
            f"({BASELINE_FLOOR}). Abortando."
        )
    owners = scan_plugin_vocabulary(args.profile_node_modules)
    results = []
    if os.path.isdir(args.sessions):
        for workspace in sorted(os.listdir(args.sessions)):
            ws_dir = os.path.join(args.sessions, workspace)
            if not os.path.isdir(ws_dir):
                continue
            for sid in sorted(os.listdir(ws_dir)):
                info = classify_session(os.path.join(ws_dir, sid), baseline, owners)
                if info is None:
                    continue
                info["workspace"] = workspace
                results.append(info)
    json.dump({"sessions": results, "baselineCount": len(baseline)},
              sys.stdout, indent=2)
    print()
    if args.fail_on_risk:
        if any(r["risk"] == "broken" for r in results):
            sys.exit(4)
        if any(r["risk"] == "at-risk" for r in results):
            sys.exit(3)
```

Y registrar el subcomando dentro de `main()`, después del parser de `baseline`:

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
Expected: PASS — 8 tests verdes.

- [ ] **Step 5: Verificar contra las sesiones reales**

Run:
```bash
python3 plugins/session-scan.py scan \
  --sessions "$HOME/.dsh/sessions" \
  --harness "$HOME/.local/dsh-node/node24/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js" \
  --profile-node-modules "$HOME/.dsh/profiles/web/node_modules" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(s["risk"], s["workspace"], s["id"]) for s in d["sessions"] if s["risk"]!="ok"]'
```
Expected: la sesión `session-67436620-…` de `--opt-vpn-monitor-mke--` aparece como `at-risk` con owner `dsh-swarm-panel@0.1.0` (está instalado hoy).

- [ ] **Step 6: Commit**

```bash
git add plugins/session-scan.py tests/session-backup.bats
git commit -m "feat(session-backup): escaneo de logs y clasificacion de riesgo"
```

---

### Task 3: Subcomando `session-backup scan` en dsh-manage.sh

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `plugins/session-scan.py scan` de la Task 2, `$DSH_MANAGE_DIR`, `$DSH_HOME`, `$DSH_NODE`.
- Produces: función bash `session_backup_scan()`; `dsh_session_lib_path()` que devuelve la ruta al `index.js` del harness.

- [ ] **Step 1: Escribir el test que falla**

Agregar a `tests/session-backup.bats`:

```bash
@test "session-backup sin subcomando imprime uso y falla" {
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup
  [ "$status" -ne 0 ]
  [[ "$output" == *"uso:"* ]]
  [[ "$output" == *"scan"* ]]
}

@test "session-backup scan sin sesiones no falla" {
  mkdir -p "$DSH_HOME/sessions"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"sin sesiones"* ]] || [[ "$output" == *"0 sesiones"* ]]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — el comando `session-backup` no existe en el dispatcher.

- [ ] **Step 3: Escribir la implementación**

Agregar en `dsh-manage.sh`, justo antes de `update() {`:

```bash
# Raiz de snapshots: HERMANA de sessions/, nunca hija — todo lo que cuelga de
# sessions/ es candidato a que el backend lo enumere como una sesion mas.
DSH_BACKUP_ROOT="${DSH_BACKUP_ROOT:-$DSH_HOME/session-backups}"

# Ruta al index.js de @deepseek-ai/dsh-session dentro del harness instalado.
# De ahi sale el baseline de tipos de evento; nunca se hardcodea la lista.
dsh_session_lib_path() {
  echo "$DSH_PREFIX/lib/node_modules/$DSH_PKG/node_modules/@deepseek-ai/dsh-session/lib/index.js"
}

# Preflight: las herramientas que el helper y los snapshots necesitan.
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
}

# scan: clasifica las sesiones por riesgo. SOLO LECTURA sobre sessions/.
session_backup_scan() {
  session_backup_preflight || return 1
  local sessions_dir="$DSH_HOME/sessions"
  if [ ! -d "$sessions_dir" ]; then
    echo "sin sesiones que revisar ($sessions_dir no existe)"
    return 0
  fi
  local args=(
    "$DSH_MANAGE_DIR/plugins/session-scan.py" scan
    --sessions "$sessions_dir"
    --harness "$(dsh_session_lib_path)"
  )
  local profile_nm="$DSH_HOME/profiles/${1:-web}/node_modules"
  [ -d "$profile_nm" ] && args+=(--profile-node-modules "$profile_nm")
  local out rc=0
  out="$(python3 "${args[@]}")" || rc=$?
  [ $rc -ne 0 ] && { echo "$out"; return $rc; }
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d["sessions"]
if not rows:
    print("0 sesiones encontradas")
    sys.exit(0)
print(f"{\"workspace\":32} {\"sesion\":24} {\"eventos\":>8}  {\"riesgo\":12} dueno")
for r in rows:
    owners = ", ".join(
        f"{u[\"owner\"] or \"sin dueno\"} ({u[\"count\"]} ev. {u[\"type\"]})"
        for u in r.get("unknownTypes", [])
    ) or "—"
    print(f"{r[\"workspace\"][:32]:32} {r[\"id\"][:24]:24} {r[\"events\"]:>8}  {r[\"risk\"]:12} {owners}")
risky = [r for r in rows if r["risk"] != "ok"]
print()
if risky:
    print(f"{len(risky)} sesion(es) no-ok de {len(rows)}.")
    print("   → dsh-manage session-backup create --only-at-risk --label pre-cambios")
else:
    print(f"{len(rows)} sesiones, todas ok.")
'
}
```

Y en el dispatcher `case`, agregar antes de `version)`:

```bash
  session-backup)   session_backup "${2:-}" "${@:3}" ;;
```

Más la función despachadora, justo después de `session_backup_scan()`:

```bash
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

Y actualizar la línea de uso del dispatcher principal para incluir `session-backup`.

- [ ] **Step 4: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 5: Verificar contra el host real**

Run: `./dsh-manage.sh session-backup scan`
Expected: tabla con las sesiones; `--opt-vpn-monitor-mke--` marcada `at-risk`.

- [ ] **Step 6: Commit**

```bash
git add dsh-manage.sh tests/session-backup.bats
git commit -m "feat(session-backup): subcomando scan"
```

---

### Task 4: Subcomandos `create`, `list` y `verify`

**Files:**
- Modify: `dsh-manage.sh`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: `session_backup_scan()` y `session_backup_preflight()` de la Task 3.
- Produces: `session_backup_create()`, `session_backup_list()`, `session_backup_verify()`. Snapshot en `$DSH_BACKUP_ROOT/<UTC>-<label>/` con `MANIFEST.json`, `CHECKSUMS.sha256`, `sessions/<workspace>/<id>/<artifact>`.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/session-backup.bats`:

```bash
@test "create produce snapshot con manifest y checksums verificables" {
  h="$(fake_harness 48)"
  mkdir -p "$DSH_HOME/sessions"
  fake_session "$DSH_HOME/sessions" "--tmp-x--" "session-xxx" \
    '{"type":"tipo/0","seq":1,"time":1,"data":{}}'
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label prueba
  [ "$status" -eq 0 ]
  snap="$(ls -d "$DSH_HOME"/session-backups/*-prueba)"
  [ -f "$snap/MANIFEST.json" ]
  [ -f "$snap/CHECKSUMS.sha256" ]
  [ -f "$snap/sessions/--tmp-x--/session-xxx/session.jsonl.zstd" ]
  ( cd "$snap" && sha256sum -c CHECKSUMS.sha256 )
}

@test "create no escribe nada bajo sessions/" {
  h="$(fake_harness 48)"
  mkdir -p "$DSH_HOME/sessions"
  fake_session "$DSH_HOME/sessions" "--tmp-y--" "session-yyy" \
    '{"type":"tipo/0","seq":1,"time":1,"data":{}}'
  before="$(find "$DSH_HOME/sessions" -type f | sort)"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label limpio
  [ "$status" -eq 0 ]
  after="$(find "$DSH_HOME/sessions" -type f | sort)"
  [ "$before" = "$after" ]
}

@test "list muestra el snapshot creado y verify lo valida" {
  h="$(fake_harness 48)"
  mkdir -p "$DSH_HOME/sessions"
  fake_session "$DSH_HOME/sessions" "--tmp-z--" "session-zzz" \
    '{"type":"tipo/0","seq":1,"time":1,"data":{}}'
  bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup create --label listable
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup list
  [ "$status" -eq 0 ]
  [[ "$output" == *"listable"* ]]
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup verify --from latest
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "un snapshot .partial no aparece en list" {
  mkdir -p "$DSH_HOME/session-backups/20260101T000000Z-roto.partial"
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" session-backup list
  [ "$status" -eq 0 ]
  [[ "$output" != *"roto"* ]]
}
```

- [ ] **Step 2: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — `create` no es un subcomando válido.

- [ ] **Step 3: Escribir la implementación**

Agregar a `dsh-manage.sh`, después de `session_backup_scan()`:

```bash
# create: snapshot atomico de las sesiones. Construye en <nombre>.partial/ y
# renombra al final — un directorio con nombre final es, por invariante, un
# snapshot completo. Copia, nunca mueve: el original se abre solo en lectura.
session_backup_create() {
  session_backup_preflight || return 1
  umask 077
  local label="manual" only_at_risk=0 profile="web"
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label="${2:-manual}"; shift 2 ;;
      --only-at-risk) only_at_risk=1; shift ;;
      --profile) profile="${2:-web}"; shift 2 ;;
      *) echo "opcion desconocida para create: $1" >&2; return 1 ;;
    esac
  done

  local sessions_dir="$DSH_HOME/sessions"
  if [ ! -d "$sessions_dir" ]; then
    echo "sin sesiones que resguardar ($sessions_dir no existe)"
    return 2
  fi

  mkdir -p "$DSH_BACKUP_ROOT"
  local stamp snap partial
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  snap="$DSH_BACKUP_ROOT/${stamp}-${label}"
  partial="${snap}.partial"
  mkdir -p "$partial/sessions"

  # Lock: dos colegas corriendo create en paralelo no se pisan.
  exec 9>"$DSH_BACKUP_ROOT/.lock"
  flock -w 30 9 || { echo "otro session-backup esta corriendo" >&2; return 1; }

  local scan_json
  scan_json="$(python3 "$DSH_MANAGE_DIR/plugins/session-scan.py" scan \
    --sessions "$sessions_dir" \
    --harness "$(dsh_session_lib_path)" \
    ${DSH_HOME:+--profile-node-modules "$DSH_HOME/profiles/$profile/node_modules"})" || {
      rm -rf "$partial"; echo "fallo el scan previo" >&2; return 1; }
  printf '%s\n' "$scan_json" > "$partial/scan.json"

  # El helper decide que copiar y arma el manifest; bash solo orquesta.
  DSH_SNAP_DIR="$partial" DSH_SESSIONS_DIR="$sessions_dir" \
  DSH_LABEL="$label" DSH_STAMP="$stamp" DSH_ONLY_AT_RISK="$only_at_risk" \
  DSH_PROFILE="$profile" DSH_MANAGE_VERSION="$DSH_MANAGE_VERSION" \
  python3 "$DSH_MANAGE_DIR/plugins/session-scan.py" snapshot \
    --scan-json "$partial/scan.json" || {
      rm -rf "$partial"; echo "fallo la creacion del snapshot" >&2; return 1; }

  ( cd "$partial" && sha256sum -c CHECKSUMS.sha256 >/dev/null ) || {
    rm -rf "$partial"; echo "checksums no verifican, snapshot descartado" >&2; return 1; }

  mv -T "$partial" "$snap"
  ln -sfn "$(basename "$snap")" "$DSH_BACKUP_ROOT/.latest.tmp"
  mv -T "$DSH_BACKUP_ROOT/.latest.tmp" "$DSH_BACKUP_ROOT/latest"
  echo "snapshot creado: $snap"
}

# list: snapshots completos (los .partial se ignoran por invariante).
session_backup_list() {
  if [ ! -d "$DSH_BACKUP_ROOT" ]; then
    echo "no hay snapshots ($DSH_BACKUP_ROOT no existe)"
    return 0
  fi
  local found=0 dir
  for dir in "$DSH_BACKUP_ROOT"/*/; do
    [ -d "$dir" ] || continue
    case "$dir" in *.partial/) continue ;; esac
    [ -f "${dir}MANIFEST.json" ] || continue
    found=1
    python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(f"{m[\"createdAt\"]}  {m[\"label\"]:28} {len(m[\"sessions\"]):>3} sesiones  {m.get(\"reason\",\"\")}")
' "${dir}MANIFEST.json"
  done
  [ "$found" -eq 0 ] && echo "no hay snapshots completos"
  return 0
}

# verify: integridad de un snapshot (checksums + zstd -t + header parseable).
session_backup_verify() {
  local from="latest"
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-latest}"; shift 2 ;;
      *) echo "opcion desconocida para verify: $1" >&2; return 1 ;;
    esac
  done
  local snap="$DSH_BACKUP_ROOT/$from"
  [ -d "$snap" ] || { echo "snapshot no encontrado: $snap" >&2; return 1; }
  ( cd "$snap" && sha256sum -c CHECKSUMS.sha256 >/dev/null ) \
    || { echo "checksums FALLAN en $snap" >&2; return 1; }
  local artifact
  while IFS= read -r artifact; do
    case "$artifact" in
      *.zstd) zstd -t "$artifact" >/dev/null 2>&1 \
                || { echo "zstd corrupto: $artifact" >&2; return 1; } ;;
    esac
  done < <(find "$snap/sessions" -type f 2>/dev/null)
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

Agregar a `plugins/session-scan.py` el subcomando `snapshot` (copia los artefactos, escribe `MANIFEST.json` y `CHECKSUMS.sha256`), antes de `main()`:

```python
import hashlib
import shutil
from datetime import datetime, timezone


def cmd_snapshot(args):
    """Copia los artefactos y escribe MANIFEST.json + CHECKSUMS.sha256.

    Copia, nunca mueve. Lee el original en modo binario y no lo modifica.
    """
    snap = os.environ["DSH_SNAP_DIR"]
    sessions_dir = os.environ["DSH_SESSIONS_DIR"]
    only_at_risk = os.environ.get("DSH_ONLY_AT_RISK") == "1"
    with open(args.scan_json, encoding="utf-8") as f:
        scan = json.load(f)

    entries, checksums = [], []
    for row in scan["sessions"]:
        if only_at_risk and row["risk"] == "ok":
            continue
        src = os.path.join(sessions_dir, row["workspace"], _dir_of(sessions_dir, row), row["artifact"])
        if not os.path.isfile(src):
            continue
        rel = os.path.join("sessions", row["workspace"], os.path.basename(os.path.dirname(src)), row["artifact"])
        dst = os.path.join(snap, rel)
        os.makedirs(os.path.dirname(dst), mode=0o700, exist_ok=True)
        shutil.copy2(src, dst)
        os.chmod(dst, 0o600)
        digest = hashlib.sha256()
        with open(dst, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                digest.update(chunk)
        checksums.append(f"{digest.hexdigest()}  {rel}")
        entry = dict(row)
        entry["sha256"] = digest.hexdigest()
        entry["bytes"] = os.path.getsize(dst)
        entries.append(entry)

    manifest = {
        "schemaVersion": 1,
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "label": os.environ.get("DSH_LABEL", "manual"),
        "reason": os.environ.get("DSH_REASON", ""),
        "dshManageVersion": os.environ.get("DSH_MANAGE_VERSION", "?"),
        "dshHome": os.path.dirname(sessions_dir),
        "profile": os.environ.get("DSH_PROFILE", "web"),
        "baselineCount": scan.get("baselineCount"),
        "sessions": entries,
    }
    with open(os.path.join(snap, "MANIFEST.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    with open(os.path.join(snap, "CHECKSUMS.sha256"), "w", encoding="utf-8") as f:
        f.write("\n".join(checksums) + ("\n" if checksums else ""))


def _dir_of(sessions_dir, row):
    """El directorio de la sesion: el id del header puede no coincidir con el
    nombre del directorio (el prefijo `session-` es inconsistente en el host),
    asi que se busca por contenido."""
    ws = os.path.join(sessions_dir, row["workspace"])
    for candidate in os.listdir(ws):
        if os.path.isfile(os.path.join(ws, candidate, row["artifact"])):
            if candidate == row["id"] or candidate.endswith(row["id"]) or row["id"].endswith(candidate):
                return candidate
    return row["id"]
```

y su registro en `main()`:

```python
    p = sub.add_parser("snapshot", help="copia artefactos y escribe manifest (uso interno)")
    p.add_argument("--scan-json", required=True)
    p.set_defaults(func=cmd_snapshot)
```

- [ ] **Step 4: Correr los tests para ver que pasan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS + shellcheck limpio.

- [ ] **Step 5: Verificar contra el host real**

Run: `./dsh-manage.sh session-backup create --label verificacion && ./dsh-manage.sh session-backup verify --from latest`
Expected: snapshot creado y `OK — … integro`. Confirmar que `find "$HOME/.dsh/sessions" -newer …` no muestra archivos nuevos.

- [ ] **Step 6: Commit**

```bash
git add dsh-manage.sh plugins/session-scan.py tests/session-backup.bats
git commit -m "feat(session-backup): subcomandos create, list y verify"
```

---

### Task 5: Patch local de dsh-swarm-panel (`ignorable: true`)

**Files:**
- Create: `plugins/patches/dsh-swarm-panel@0.1.0.patch`
- Modify: `plugins/manifest.json`
- Test: `tests/session-backup.bats`

**Interfaces:**
- Consumes: nada de tareas previas.
- Produces: entrada `patchedDependencies["dsh-swarm-panel@0.1.0"]` y clave `sessionEventWriters` en el manifest.

- [ ] **Step 1: Localizar el punto exacto del append**

Run:
```bash
grep -n "append(" "$HOME/.dsh/profiles/web/node_modules/dsh-swarm-panel/lib/index.js" | head -20
```
Expected: la(s) llamada(s) que escriben eventos `swarm/*` a la sesión. Anotar el número de línea y la forma exacta del objeto que se pasa.

- [ ] **Step 2: Escribir el test que falla**

Agregar a `tests/session-backup.bats`:

```bash
@test "el manifest declara el patch de swarm-panel y sus event writers" {
  run python3 -c "
import json
m = json.load(open('$BATS_TEST_DIRNAME/../plugins/manifest.json'))
assert 'dsh-swarm-panel@0.1.0' in m['patchedDependencies'], 'falta el patch en patchedDependencies'
assert 'sessionEventWriters' in m, 'falta la clave sessionEventWriters'
assert 'dsh-swarm-panel' in m['sessionEventWriters'], 'swarm-panel no declarado como event writer'
"
  [ "$status" -eq 0 ]
}

@test "el archivo de patch de swarm-panel existe y menciona ignorable" {
  p="$BATS_TEST_DIRNAME/../plugins/patches/dsh-swarm-panel@0.1.0.patch"
  [ -f "$p" ]
  grep -q "ignorable" "$p"
}
```

- [ ] **Step 3: Correr los tests para ver que fallan**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats`
Expected: FAIL — no existe el patch ni la clave en el manifest.

- [ ] **Step 4: Generar el patch con pnpm**

```bash
export PATH="$HOME/.local/dsh-node/bin:$HOME/.local/dsh-node/node24/bin:$PATH"
cd "$HOME/.dsh/profiles/web"
pnpm patch dsh-swarm-panel@0.1.0
```
Editar en el directorio que imprime pnpm: en cada llamada que escribe un evento `swarm/*`, agregar `ignorable: true` al envelope (mismo mecanismo que `dsh-defend` usa para su audit). Luego:
```bash
pnpm patch-commit '<ruta que imprimio pnpm>'
```

- [ ] **Step 5: Copiar el patch al repo y registrarlo**

```bash
cp "$HOME/.dsh/profiles/web/patches/dsh-swarm-panel@0.1.0.patch" /opt/dsh-manage/plugins/patches/
```

En `plugins/manifest.json`, agregar a `patchedDependencies`:
```json
"dsh-swarm-panel@0.1.0": "patches/dsh-swarm-panel@0.1.0.patch"
```
y una clave nueva de primer nivel:
```json
"sessionEventWriters": {
  "dsh-swarm-panel": {
    "prefixes": ["swarm/"],
    "note": "registra su vocabulario en KNOWN_SESSION_EVENT_TYPES como efecto de ciclo de vida; al descargarlo, las sesiones con eventos swarm/* dejan de cargar. El patch local hace que emita ignorable:true para que sobrevivan a la desinstalacion."
  }
}
```
Y a `patchNotes`:
```json
"dsh-swarm-panel@0.1.0": "Emite ignorable:true en los eventos swarm/* para que las sesiones sigan cargando si el plugin se desinstala. Sin este patch, desinstalarlo deja ilegibles las sesiones que lo usaron (incidente real: session-67436620 de vpn-monitor-mke)."
```

- [ ] **Step 6: Verificar que el patch funciona de verdad**

```bash
systemctl restart dsh.service && sleep 6
curl -sS -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://127.0.0.1:3080/
```
Crear una sesión nueva, pedir un swarm, y comprobar que los eventos nuevos llevan la marca:
```bash
zstd -dc "$HOME/.dsh/sessions/<ws>/<nueva-sesion>/session.jsonl.zstd" \
  | python3 -c 'import json,sys; [print(json.loads(l).get("ignorable")) for l in sys.stdin if "swarm/" in l]' | sort -u
```
Expected: `True` (no `None`).

- [ ] **Step 7: Correr los tests**

Run: `cd /opt/dsh-manage && bats tests/session-backup.bats && make check`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add plugins/patches/dsh-swarm-panel@0.1.0.patch plugins/manifest.json tests/session-backup.bats
git commit -m "fix(swarm-panel): patch local para emitir ignorable:true en eventos swarm"
```

---

### Task 6: Documentación

**Files:**
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: los subcomandos de las Tasks 3-4 y el patch de la Task 5.

- [ ] **Step 1: Documentar en el README**

Agregar a la tabla de comandos:
```markdown
| `session-backup {scan,create,list,verify}` | Resguardo de sesiones: clasifica riesgo y crea snapshots verificables |
```

Y una sección nueva después de `service-install`:

````markdown
### `session-backup`: resguardo de sesiones

Algunos plugins (`dsh-swarm-panel` y otros *event-writers*) registran tipos de
evento propios en el harness **mientras están cargados**. Si se desinstalan,
las sesiones que usaron esos eventos dejan de cargar
(`SessionFormatUnsupportedError`). Pasó de verdad en este proyecto.

```bash
dsh-manage session-backup scan       # ¿qué sesiones están en riesgo?
dsh-manage session-backup create --only-at-risk --label pre-cambios
dsh-manage session-backup list
dsh-manage session-backup verify --from latest
```

Clasificación de `scan`:

| Clase | Significado |
|---|---|
| `ok` | Solo tipos first-party. Inmune a instalar/desinstalar plugins. |
| `at-risk` | Tiene tipos de un plugin **instalado**. Carga hoy; se rompe si lo desinstalás. |
| `broken` | Tiene tipos que ningún plugin instalado declara. Ya no carga. |

`scan`, `create`, `list` y `verify` **nunca escriben bajo `sessions/`**. Los
snapshots viven en `$DSH_HOME/session-backups/` (hermano de `sessions/`), con
`MANIFEST.json` y `CHECKSUMS.sha256` — recuperables a mano con `cp` y
verificables con `sha256sum -c` sin necesitar este script.

> `restore`, `repair` y la integración automática con `plugins-remove`
> corresponden a una fase posterior — ver `docs/SESSION-BACKUP-DESIGN.md`.
````

Agregar a la tabla de variables de entorno:
```markdown
| `DSH_BACKUP_ROOT`   | `$DSH_HOME/session-backups`            | Raíz de los snapshots de sesión          |
```

- [ ] **Step 2: Documentar en el CHANGELOG**

Bajo `## [Unreleased]`, sección `### Agregado`:
```markdown
- `dsh-manage session-backup {scan,create,list,verify}` — resguardo de sesiones
  ante plugins que escriben eventos propios. `scan` clasifica cada sesión en
  `ok`/`at-risk`/`broken` extrayendo el catálogo de tipos del harness instalado
  (48 tipos hoy, con piso de cordura de 20 para no clasificar todo como roto si
  el parseo falla). `create` produce snapshots atómicos verificables
  (`MANIFEST.json` + `CHECKSUMS.sha256`), fuera de `sessions/`. Ninguno de estos
  subcomandos escribe bajo `sessions/`. Diseño completo en
  `docs/SESSION-BACKUP-DESIGN.md`.
- `plugins/patches/dsh-swarm-panel@0.1.0.patch` — hace que el plugin emita
  `ignorable: true` en sus eventos `swarm/*`, de modo que las sesiones que lo
  usen sigan cargando aunque se lo desinstale. Sin este patch, desinstalarlo
  dejaba ilegibles las sesiones afectadas (incidente real con
  `session-67436620` de `vpn-monitor-mke`).
- `plugins/manifest.json`: clave `sessionEventWriters`, que documenta qué
  paquetes escriben eventos de sesión y con qué prefijos.
```

- [ ] **Step 3: Verificación final completa**

Run: `cd /opt/dsh-manage && make check && make bats`
Expected: shellcheck limpio y todos los tests verdes (los previos + los nuevos).

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs(session-backup): documentar scan/create/list/verify y el patch de swarm-panel"
```

---

## Self-Review

**1. Cobertura del spec (Fases 1-2 + enmienda):**
- §3.1 baseline con piso de cordura → Task 1 ✅
- §3.2 vocabulario de plugins escaneando `node_modules` real → Task 2 ✅
- §3.3 escaneo de logs con `ignorable === true` estricto → Task 2 ✅
- §3.4 clasificación `ok`/`at-risk`/`broken`/`unsupported-version`/`unreadable` → Task 2 ✅
- §2 layout de snapshot, `.partial` + rename atómico, `latest` → Task 4 ✅
- §2.1 `MANIFEST.json` + `CHECKSUMS.sha256` → Task 4 ✅
- §5.1 invariante "no escribir bajo `sessions/`" → Task 4, test dedicado ✅
- §5.3 lock con `flock` → Task 4 ✅
- §5.4 permisos `0700`/`0600` + `umask 077` → Task 4 ✅
- §5.6 códigos de salida 3/4 en `--fail-on-risk` → Task 2 ✅
- §7.2 enmienda de `session_projcache.json` → **fuera de alcance declarado** (pertenece a la fase de `restore`) ✅
- Fix upstream del plugin → Task 5 ✅

**Gaps conocidos y aceptados:** `vocabulary.json` dentro del snapshot (§2.1) queda cubierto parcialmente — el `scan.json` guarda el mapa `tipo → dueño`, que es el dato que importa para saber qué reinstalar. Un `vocabulary.json` separado se agrega en la fase de `restore`, que es quien lo consume. `--dry-run`, `--json` y `--quiet` globales no se implementan en estas fases (no hay operación destructiva que justifique `--dry-run` todavía).

**2. Placeholders:** ninguno — todos los pasos tienen el código real o el comando exacto.

**3. Consistencia de tipos:** `session_backup_preflight()` y `dsh_session_lib_path()` se definen en Task 3 y se consumen en Task 4. El JSON de `scan` (claves `sessions[].workspace/id/artifact/risk/events/unknownTypes`) se produce en Task 2 y se consume en Tasks 3 y 4 con esos mismos nombres. `DSH_BACKUP_ROOT` se define en Task 3 y se usa en Task 4.
