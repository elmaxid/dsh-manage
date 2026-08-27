#!/usr/bin/env python3
"""Helper de `dsh-manage session-backup`: extrae el baseline de tipos de
evento del harness, escanea el vocabulario de los plugins instalados, lee los
logs de sesion y clasifica el riesgo. Emite JSON a stdout.

Nunca escribe bajo $DSH_HOME/sessions/ — es de solo lectura sobre las sesiones.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

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
    # Supuesto: asume que ningun tipo de evento contiene el caracter ']' —
    # verificado contra el harness real al momento de escribir esto. Si algun
    # dia aparece un tipo con ']', este find cortaria prematuramente y el
    # baseline quedaria incompleto; ante la duda, migrar a un parseo robusto.
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
        try:
            with open(args.known, encoding="utf-8") as f:
                known_types = json.load(f).get("types", [])
        except json.JSONDecodeError:
            raise SystemExit(f"el archivo vendorizado {args.known} no es JSON valido")
        # M3: un string u otro no-lista convierte a set de caracteres sin
        # error; validar el tipo antes de construir el set.
        if not isinstance(known_types, list):
            raise SystemExit(
                f"el campo 'types' del vendorizado {args.known} debe ser una lista"
            )
        known = set(known_types)
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


def main():
    parser = argparse.ArgumentParser(prog="session-scan.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("baseline", help="extrae el catalogo first-party del harness")
    p.add_argument("--harness", required=True, help="ruta a dsh-session/lib/index.js")
    p.add_argument("--known", default=None, help="baseline vendorizado, para comparar")
    p.set_defaults(func=cmd_baseline)
    p = sub.add_parser("scan", help="clasifica las sesiones por riesgo")
    p.add_argument("--sessions", required=True, help="ruta a $DSH_HOME/sessions")
    p.add_argument("--harness", required=True, help="ruta a dsh-session/lib/index.js")
    p.add_argument("--profile-node-modules", default=None,
                   help="node_modules del profile, para mapear tipo -> plugin")
    p.add_argument("--fail-on-risk", action="store_true",
                   help="sale 3 si hay at-risk, 4 si hay broken")
    p.set_defaults(func=cmd_scan)
    p = sub.add_parser("snapshot", help="copia artefactos y escribe manifest (uso interno)")
    p.add_argument("--scan-json", required=True)
    p.add_argument("--snap-dir", required=True)
    p.add_argument("--sessions", required=True)
    p.set_defaults(func=cmd_snapshot)
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
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()