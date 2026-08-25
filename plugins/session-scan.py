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