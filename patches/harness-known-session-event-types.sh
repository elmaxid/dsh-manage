#!/usr/bin/env bash
# harness-known-session-event-types.sh — re-aplica el parche de tipos de
# eventos de sesión de plugins sobre el harness DSH instalado.
#
# Problema: los plugins (hoy dsh-kimicode-swarm con "swarm/progress") agregan
# eventos propios al log de sesión. Session.append() en dsh-session@0.1.1-rc.2
# descarta el flag `ignorable` (arreglado solo en master upstream), y el lector
# (dsh-session-persistence, assertEventsSupported) rechaza cualquier tipo que
# no esté en KNOWN_SESSION_EVENT_TYPES y no venga marcado `ignorable:true`.
# Resultado: SessionFormatUnsupportedError y el historial deja de cargar.
#
# Este parche declara el tipo como conocido en el Set del harness instalado.
# Es idempotente, hace backup previo y verifica importando el módulo real.
# Se pierde con cada actualización del harness: re-ejecutar este script.
#
# Uso:      patches/harness-known-session-event-types.sh [--check]
# Efecto:   completo tras reiniciar dsh (el módulo vive en cache del proceso).
# Override: HARNESS_SESSION_TYPES_TARGET=<ruta index.js> para probar contra
#           otra copia (usado por smoke/tests).
set -euo pipefail

# Tipos de eventos de plugins a declarar conocidos.
TYPES=("swarm/progress")

# Resolver la copia de @deepseek-ai/dsh-session que usa el binario dsh:
# subir por los ancestros del binario real hasta encontrar el paquete.
resolve_target() {
	local dsh_bin real dir
	dsh_bin="$(command -v dsh || true)"
	if [ -z "$dsh_bin" ]; then
		echo "ERROR: no se encontró el binario dsh en PATH" >&2
		exit 1
	fi
	real="$(readlink -f "$dsh_bin")"
	dir="$(dirname "$real")"
	while [ "$dir" != "/" ]; do
		if [ -f "$dir/node_modules/@deepseek-ai/dsh-session/lib/index.js" ]; then
			echo "$dir/node_modules/@deepseek-ai/dsh-session/lib/index.js"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	echo "ERROR: no se encontró @deepseek-ai/dsh-session como ancestro de $real" >&2
	exit 1
}

TARGET="${HARNESS_SESSION_TYPES_TARGET:-$(resolve_target)}"
if [ ! -f "$TARGET" ]; then
	echo "ERROR: no existe $TARGET" >&2
	exit 1
fi

missing_types() {
	node -e '
import(process.argv[1]).then(m => {
  const missing = process.argv.slice(2).filter(t => !m.KNOWN_SESSION_EVENT_TYPES.has(t));
  console.log(missing.length ? missing.join(",") : "OK");
}).catch(() => console.log("MODULE_ERROR"))
' "$TARGET" "${TYPES[@]}" 2>/dev/null
}

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

STATE="$(missing_types)"
case "$STATE" in
	OK)
		echo "OK: todos los tipos ya están declarados en $TARGET"
		exit 0
		;;
	MODULE_ERROR)
		echo "ERROR: el módulo no se puede importar ($TARGET)" >&2
		exit 1
		;;
esac
if [ "$CHECK_ONLY" = 1 ]; then
	echo "PATCH NEEDED: faltan tipos: $STATE"
	exit 3
fi

BACKUP="$TARGET.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$TARGET" "$BACKUP"
echo "Backup: $BACKUP"

TARGET="$TARGET" STATE="$STATE" node <<'EOF'
const fs = require("fs");
const target = process.env.TARGET;
const missing = process.env.STATE.split(",").filter(Boolean);
let src = fs.readFileSync(target, "utf8");
// Fin del set KNOWN_SESSION_EVENT_TYPES: último tipo (con o sin coma) + `]);`.
const re = /(\t"web\/deepseek-search-llm-request",?)\n\]\);/;
if (!re.test(src)) {
	console.error("ERROR: ancla de KNOWN_SESSION_EVENT_TYPES no encontrada; el formato del harness cambió — parchear a mano.");
	process.exit(1);
}
const insert = missing.map((t) => `\t${JSON.stringify(t)}, // dsh-manage patch: ver /opt/dsh-manage/patches/\n`).join("");
src = src.replace(re, (_m, last) => `${last.endsWith(",") ? last : last + ","}\n${insert}]);`);
fs.writeFileSync(target, src);
EOF

STATE_AFTER="$(missing_types)"
if [ "$STATE_AFTER" = "OK" ]; then
	echo "OK: parche aplicado y verificado ($TARGET). Reiniciar dsh para que tome efecto."
else
	echo "ERROR: tras parchear el estado es '$STATE_AFTER' — revisar $BACKUP" >&2
	exit 1
fi
