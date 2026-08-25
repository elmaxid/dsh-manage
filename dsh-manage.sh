#!/usr/bin/env bash
#
# dsh-manage — instalación y administración de DeepSeek Harness (dsh).
#
# Controla el ciclo de vida del servidor web de DSH: instalar, iniciar,
# detener, actualizar y consultar estado. Pensado para replicarse en los
# puestos de desarrollo y para operar sobre una instalación aislada en la
# tree de node24 (ver DSH_NODE / DSH_PREFIX más abajo).
#
# Uso:
#   dsh-manage {start|stop|update|status|install|version|check-update}
#   dsh-manage plugins-install [profile]   # instala el stack de plugins homologado
#   dsh-manage service-install              # instala el watchdog systemd
#   dsh-manage --version | -V   # versión del propio script de gestión
#
# Requiere correr como el usuario que posee el proceso de DSH (normalmente
# root). port_pid() depende de que `ss` pueda leer los pids de los sockets,
# lo que exige permisos sobre el proceso en cuestión.
#
# Variables de entorno (con defaults razonables):
#   DSH_NODE          dir del binario node/npm/dsh (default: node24 tree)
#   DSH_MANAGE_HOME   directorio de trabajo/log/pid DE ESTE SCRIPT (default: ~/dsh-test)
#   DSH_HOME          config real del binario dsh (profiles, cordis.patch.yml —
#                     default: ~/.dsh, MISMA variable que usa `dsh` internamente,
#                     no la confundas con DSH_MANAGE_HOME de arriba: si corrés
#                     dsh-manage desde una sesión de agente DSH, el propio
#                     harness ya te exporta DSH_HOME=~/.dsh en el entorno —
#                     es lo correcto para plugins-install, no para el resto)
#   DSH_PORT          puerto donde DSH escucha (default: 3080)
#   DSH_START_TIMEOUT segundos a esperar por el puerto (default: 180)
#   DSH_ALLOW_SCRIPTS paquetes con addons nativos a los que npm permite scripts
#   DSH_PKG           nombre del paquete npm (default: @deepseek-ai/dsh)
#   DSH_NPM_CACHE     cache de npm para consultas (default: $DSH_MANAGE_HOME/.npm-cache)
#   DSH_MANIFEST      manifest.json del stack de plugins (default: plugins/manifest.json junto al script)
#   DSH_SERVICE_USER  usuario que corre el systemd unit (default: usuario actual)

set -euo pipefail

# Versión del propio script de gestión (no la de @deepseek-ai/dsh — esa es
# installed_version/latest_version más abajo). Semver, sin 'v'; el CLI la
# imprime con 'v' delante. Ver CHANGELOG.md por release.
DSH_MANAGE_VERSION="1.2.0"

DSH_NODE="${DSH_NODE:-$HOME/.local/dsh-node/node24/bin}"
# Directorio de trabajo/log/pid DE ESTE SCRIPT — NO confundir con DSH_HOME,
# que es la variable que usa el binario dsh real para su propia config
# (profiles, cordis.patch.yml). Antes ambos vivían bajo el mismo nombre
# DSH_HOME acá, lo que colisionaba de verdad: correr dsh-manage desde una
# sesión de agente DSH hereda DSH_HOME=~/.dsh del entorno del harness, y ese
# valor se filtraba silenciosamente al working dir de este script.
DSH_MANAGE_HOME="${DSH_MANAGE_HOME:-$HOME/dsh-test}"
DSH_LOG="$DSH_MANAGE_HOME/dsh.log"
DSH_PID="$DSH_MANAGE_HOME/dsh.pid"
DSH_PORT="${DSH_PORT:-3080}"
DSH_START_TIMEOUT="${DSH_START_TIMEOUT:-180}"
# @deepseek-ai/dsh instalado globalmente, --prefix scoped a la tree de node24
# (el ~/.npmrc de este usuario fija prefix al Node 20 del sistema, demasiado
# viejo para dsh y compartido con otro servicio del host — --prefix acá lo
# overridea por comando sin tocar la config compartida).
DSH_PREFIX="$DSH_NODE/.."
DSH_BIN="$DSH_NODE/dsh"
# koffi, node-pty y amigos traen addons nativos; el guard de scripts de npm
# bloquea sus install/postinstall salvo que se listen explícitamente.
DSH_ALLOW_SCRIPTS="${DSH_ALLOW_SCRIPTS:-@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs}"
DSH_PKG="${DSH_PKG:-@deepseek-ai/dsh}"
# Cache propio para `npm view`: el ~/.npm/_cacache del usuario puede ser
# readonly/compartido (ej. root), lo que hace fallar la consulta. Usar un
# cache scoped a DSH_MANAGE_HOME evita chocar con el cache compartido.
DSH_NPM_CACHE="${DSH_NPM_CACHE:-$DSH_MANAGE_HOME/.npm-cache}"

# Config real del binario dsh (default ~/.dsh, MISMA convención que usa dsh
# internamente — "the profile under $DSH_HOME/profiles to boot" según su
# propio --help). A propósito NO se inventa una variable separada acá:
# plugins_install() tiene que escribir exactamente donde el binario real va
# a buscar, y ese lugar es $DSH_HOME/profiles/<name>, no otro.
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
# Directorio del propio script (para resolver plugins/manifest.json relativo
# al repo, sin depender del cwd desde donde se invoque dsh-manage).
# readlink -f resuelve symlinks: si dsh-manage se invoca vía un symlink en
# $PATH (ej. /usr/local/bin/dsh-manage -> el repo clonado, que es lo que
# instala install.sh), dirname "${BASH_SOURCE[0]}" a secas devolvería el
# directorio del symlink (/usr/local/bin), no el del repo real donde vive
# plugins/ — confirmado con una prueba mínima, no era solo una hipótesis.
DSH_MANAGE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DSH_MANIFEST="${DSH_MANIFEST:-$DSH_MANAGE_DIR/plugins/manifest.json}"
DSH_SERVICE_USER="${DSH_SERVICE_USER:-$(id -un)}"

mkdir -p "$DSH_MANAGE_HOME"

# El pid que escucha el puerto es la autoridad: un pidfile solo puede quedar
# stale tras un reboot/crash (el PID puede ser reutilizado por otro proceso).
port_pid() {
  ss -ltnp 2>/dev/null | awk -v port=":$DSH_PORT " '
    index($0, port) {
      if (match($0, /pid=[0-9]+/)) {
        pid = substr($0, RSTART + 4, RLENGTH - 4)
        print pid
      }
    }' | head -1
}

# default de timeout intencional: siempre se llama sin args
# shellcheck disable=SC2119,SC2120
wait_for_port() {
  local attempts="${1:-$DSH_START_TIMEOUT}"
  local i
  for ((i = 0; i < attempts; i++)); do
    if [ -n "$(port_pid)" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ¿Hay un binario node ejecutable en DSH_NODE? Puesto sin Node instalado
# todavía (equipo nuevo del staff, réplica limpia) da falso acá.
node_available() {
  [ -x "$DSH_NODE/node" ]
}

# URL del tarball oficial de nodejs.org para una versión + arquitectura dadas
# (uname -m). Solo mapea las arquitecturas que nodejs.org publica para Linux;
# cualquier otra falla explícito en vez de armar una URL que 404.
# @param $1 version (ej. v24.19.0, con la 'v')
# @param $2 arquitectura de uname -m (ej. x86_64, aarch64)
node_download_url() {
  local version="$1" arch="$2" node_arch
  case "$arch" in
    x86_64|amd64) node_arch="x64" ;;
    aarch64|arm64) node_arch="arm64" ;;
    *)
      echo "arquitectura no soportada para bootstrap de node: $arch" >&2
      return 1
      ;;
  esac
  echo "https://nodejs.org/dist/${version}/node-${version}-linux-${node_arch}.tar.xz"
}

# Descarga y extrae Node oficial en DSH_PREFIX si DSH_NODE no tiene un
# binario node ejecutable. Idempotente: no hace nada si node_available ya
# es verdadero. Deja el árbol igual al de un tarball extraído a mano (mismo
# layout que ya usaba este puesto antes de automatizarlo).
bootstrap_node() {
  if node_available; then
    return 0
  fi
  local version url tmp arch
  version="${DSH_NODE_VERSION:-v24.19.0}"
  arch="$(uname -m)"
  echo "node no encontrado en $DSH_NODE — descargando node $version ($arch)..."
  url="$(node_download_url "$version" "$arch")" || return 1
  tmp="$(mktemp -d)"
  if ! curl -fsSL "$url" -o "$tmp/node.tar.xz"; then
    echo "no se pudo descargar $url" >&2
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$DSH_PREFIX"
  # El tarball oficial trae un único directorio raíz (node-vX.Y.Z-linux-arch);
  # extraerlo y volcar su contenido directo en DSH_PREFIX (mismo layout que
  # el node24/ manual: bin/, lib/, include/, share/ en la raíz del prefix).
  tar -xJf "$tmp/node.tar.xz" -C "$tmp"
  local extracted
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'node-*')"
  if [ -z "$extracted" ]; then
    echo "tarball de node con layout inesperado" >&2
    rm -rf "$tmp"
    return 1
  fi
  cp -a "$extracted"/. "$DSH_PREFIX"/
  rm -rf "$tmp"
  if ! node_available; then
    echo "node se descargó pero $DSH_NODE/node sigue sin ser ejecutable" >&2
    return 1
  fi
  echo "node $("$DSH_NODE"/node --version) instalado en $DSH_PREFIX"
}

install() {
  bootstrap_node || return 1
  echo "instalando @deepseek-ai/dsh (prefix $DSH_PREFIX)..."
  # --prefix: overridea el prefix del ~/.npmrc del usuario (Node viejo) por
  # comando, sin tocar la config compartida con otros servicios del host.
  # --allow-scripts: habilita los install/postinstall de los addons nativos
  # que el guard de npm bloquea por defecto.
  PATH="$DSH_NODE:$PATH" npm install -g --prefix "$DSH_PREFIX" \
    --allow-scripts="$DSH_ALLOW_SCRIPTS" @deepseek-ai/dsh
}

start() {
  local existing
  existing=$(port_pid)
  if [ -n "$existing" ]; then
    echo "dsh ya corriendo, escuchando en :$DSH_PORT (PID $existing)"
    return 0
  fi
  if [ -f "$DSH_PID" ]; then
    echo "eliminando pidfile stale ($(cat "$DSH_PID"))"
    rm -f "$DSH_PID"
  fi
  if [ ! -x "$DSH_BIN" ]; then
    echo "dsh no instalado ($DSH_BIN no existe) — instalando primero..."
    install
  fi
  cd "$DSH_MANAGE_HOME"
  # Binario instalado (no via npx): el proceso que arranca ES el que escucha
  # el puerto. stop() igual mata por PID del puerto, que es lo autoritativo.
  # --port explícito: sin esto, DSH_PORT solo se usaba para *buscar* el
  # proceso (port_pid), nunca para decirle al binario dónde escuchar — un
  # DSH_PORT != 3080 arrancaba igual en el puerto default del profile y
  # wait_for_port nunca lo encontraba (bug real, encontrado al validar
  # plugins-install contra una instancia de prueba en otro puerto).
  PATH="$DSH_NODE:$PATH" nohup "$DSH_BIN" web --port "$DSH_PORT" --no-open > "$DSH_LOG" 2>&1 &
  local launched=$!
  echo $launched > "$DSH_PID"
  if wait_for_port; then
    echo "dsh arriba, escuchando en :$DSH_PORT (PID $(port_pid))"
    echo "log: $DSH_LOG"
    echo "http://127.0.0.1:$DSH_PORT"
  else
    echo "dsh no quedo escuchando en :$DSH_PORT, ver $DSH_LOG"
    # Evitar dejar un nohup huérfano que no llego a escuchar.
    kill "$launched" 2>/dev/null || true
    rm -f "$DSH_PID"
    return 1
  fi
}

stop() {
  # El PID del puerto es lo autoritativo (ver nota en start()); el pidfile es
  # solo limpieza extra por si acaso el listener murio pero dejo el archivo.
  local existing pf
  existing=$(port_pid)
  if [ -n "$existing" ]; then
    kill "$existing"
    echo "dsh bajado (PID $existing)"
  else
    echo "no hay dsh corriendo en :$DSH_PORT"
  fi
  if [ -f "$DSH_PID" ]; then
    pf="$(cat "$DSH_PID")"
    if [ "$pf" != "$existing" ] && kill -0 "$pf" 2>/dev/null; then
      kill "$pf" 2>/dev/null || true
    fi
    rm -f "$DSH_PID"
  fi
}

# ¿Hay un binario pnpm ejecutable en DSH_NODE? node24 trae corepack, pero
# corepack no deja el shim de pnpm listo hasta que algo lo activa una vez.
pnpm_available() {
  [ -x "$DSH_NODE/pnpm" ]
}

# corepack (bundleado con Node 16.9+) resuelve la versión de pnpm declarada
# y la deja lista como binario en la misma tree — mismo mecanismo que ya usa
# este puesto de referencia, verificado idempotente (--activate no rompe una
# instalación de pnpm ya presente ni requiere red si la versión ya está en
# el cache de corepack).
bootstrap_pnpm() {
  if pnpm_available; then
    return 0
  fi
  echo "pnpm no encontrado en $DSH_NODE — preparándolo con corepack..."
  if ! PATH="$DSH_NODE:$PATH" corepack prepare "pnpm@${DSH_PNPM_VERSION:-11.22.0}" --activate; then
    echo "no se pudo preparar pnpm via corepack" >&2
    return 1
  fi
  if ! pnpm_available; then
    echo "corepack preparó pnpm pero $DSH_NODE/pnpm sigue sin ser ejecutable" >&2
    return 1
  fi
}

# ¿El dsh.service systemd de ESTE host gestiona ESTA instancia de dsh-manage
# concreta? No basta con que el unit exista y esté enabled — un host puede
# tener un dsh.service apuntando a otro DSH_MANAGE_HOME (otro puesto lógico
# corriendo en el mismo servidor). Verificado con evidencia real: sin este
# chequeo, plugins_install() contra un profile de scratch reinició el
# dsh.service de producción por homónimo, aunque no gestionaba esa instancia.
# Compara WorkingDirectory (= DSH_MANAGE_HOME, ver service_install) — NO
# DSH_HOME, que es la config real de dsh y no aparece en el unit como cwd.
dsh_service_manages_this_home() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-enabled dsh.service >/dev/null 2>&1 || return 1
  local unit_wd
  unit_wd="$(systemctl show dsh.service -p WorkingDirectory --value 2>/dev/null)"
  [ -n "$unit_wd" ] && [ "$unit_wd" = "$DSH_MANAGE_HOME" ]
}

# Instala el stack de plugins homologado (ver plugins/manifest.json) en un
# profile de dsh. Separado de install() a propósito: install() solo pone el
# harness base; esto es una capa aparte, pensada para correrse después (o
# reintentarse sola si algo falla acá sin tocar el harness).
#
# Merge-only, nunca overwrite: si el profile ya tiene plugins instalados a
# mano, se preservan — el manifest solo agrega lo que falte (mismas reglas
# que ya se confirmaron seguras a mano con `dsh plugin add` repetido).
#
# @param $1 nombre del profile (default: web)
plugins_install() {
  local profile="${1:-web}"
  local profile_dir="$DSH_HOME/profiles/$profile"

  if [ ! -x "$DSH_BIN" ]; then
    echo "dsh no instalado ($DSH_BIN no existe) — corré 'dsh-manage install' primero" >&2
    return 1
  fi
  if [ ! -f "$DSH_MANIFEST" ]; then
    echo "manifest no encontrado: $DSH_MANIFEST" >&2
    return 1
  fi

  bootstrap_pnpm || return 1

  echo "instalando stack de plugins homologado en profile '$profile' ($profile_dir)..."
  mkdir -p "$profile_dir/patches"

  local existing_pkg="$profile_dir/package.json"
  local existing_ws="$profile_dir/pnpm-workspace.yaml"
  local merged_pkg merged_ws
  merged_pkg="$(node "$DSH_MANAGE_DIR/plugins/merge-package-json.mjs" "$existing_pkg" "$DSH_MANIFEST" "$profile")" \
    || { echo "fallo el merge de package.json" >&2; return 1; }
  merged_ws="$(python3 "$DSH_MANAGE_DIR/plugins/merge-pnpm-workspace.py" "$existing_ws" "$DSH_MANIFEST")" \
    || { echo "fallo el merge de pnpm-workspace.yaml" >&2; return 1; }

  printf '%s' "$merged_pkg" > "$existing_pkg"
  printf '%s' "$merged_ws" > "$existing_ws"

  # Copiar los .patch declarados en el manifest — no pisar uno que el humano
  # ya haya customizado a mano con el mismo nombre de archivo.
  local patch_file dest
  for patch_file in "$DSH_MANAGE_DIR"/plugins/patches/*.patch; do
    [ -e "$patch_file" ] || continue
    dest="$profile_dir/patches/$(basename "$patch_file")"
    if [ ! -f "$dest" ]; then
      cp "$patch_file" "$dest"
    fi
  done

  echo "corriendo pnpm install..."
  # pnpm (a diferencia de npm) no tiene un flag --allow-scripts: los builds
  # nativos se controlan vía pnpm-workspace.yaml (allowBuilds/strictDepBuilds,
  # ya en el manifest) + `pnpm approve-builds` después del install.
  (cd "$profile_dir" && PATH="$DSH_NODE:$PATH" pnpm install) \
    || { echo "pnpm install falló, ver arriba" >&2; return 1; }

  # Aprobar builds nativos declarados en el manifest (ssh2/cpu-features/
  # node-pty); better-sqlite3 usa prebuild y no debe aprobarse para compilar.
  local approve_pkgs
  approve_pkgs="$(node -e "
    const m = require('$DSH_MANIFEST');
    const ab = (m.pnpmWorkspace || {}).allowBuilds || {};
    console.log(Object.entries(ab).filter(([,v]) => v === true).map(([k]) => k).join(' '));
  ")"
  if [ -n "$approve_pkgs" ]; then
    # shellcheck disable=SC2086  # approve_pkgs es una lista de nombres de paquete espaciados, split intencional
    (cd "$profile_dir" && PATH="$DSH_NODE:$PATH" pnpm approve-builds $approve_pkgs) || true
  fi

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

  echo "listo: profile '$profile' con el stack de plugins activo en :$DSH_PORT"
}

# Instala el watchdog systemd de dsh: un unit que lo mantiene arriba
# (Restart=always) y un ExecStartPre defensivo (dsh-autofix.sh) que repara
# regresiones conocidas de pnpm en cada boot, sin fallar nunca el arranque.
# Idempotente: pisa el unit/script con la config actual y hace daemon-reload.
#
# CONFIRMADO NECESARIO (no solo defensa en profundidad especulativa): el fix
# de shadowing de @deepseek-ai/{dsh-tools,cosmokit,dsh-fs} local reapareció
# en una réplica real en otro host que YA tenía autoInstallPeers:false desde
# antes de correr plugins-install — ese ajuste NO es garantía suficiente por
# sí solo, sigue haciendo falta este fix. Causó "Cannot read properties of
# undefined (reading 'prepare')" (tool runtime roto) inmediatamente después
# de plugins-install, reparado a mano con el mismo rm -rf que hace este
# script — evidencia de que corre service-install justo después de
# plugins-install (no como paso opcional postergable) evita este bloqueo.
service_install() {
  local unit_path="/etc/systemd/system/dsh.service"
  local autofix_path="$DSH_MANAGE_HOME/dsh-autofix.sh"

  if [ "$(id -u)" -ne 0 ]; then
    echo "service-install requiere root (systemd unit de sistema)" >&2
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl no disponible en este host — omitir service-install" >&2
    return 1
  fi

  echo "escribiendo $autofix_path..."
  cat > "$autofix_path" <<AUTOFIX_EOF
#!/usr/bin/env bash
# Generado por 'dsh-manage service-install'. Corre como ExecStartPre de
# dsh.service, antes de cada boot (incluidos los reintentos de
# Restart=always). Repara regresiones conocidas causadas por pnpm al
# reinstalar el profile cuando se agrega/quita un plugin via Plugin Manager.
# Nunca falla el boot: cada paso es best-effort, el script siempre sale 0.

PROFILE_DIR="$DSH_HOME/profiles/web"
SCOPE_DIR="\$PROFILE_DIR/node_modules/@deepseek-ai"

# Fix 1: una reinstalación de pnpm puede hoistear una copia LOCAL de
# @deepseek-ai/{dsh-tools,cosmokit,dsh-fs} dentro del profile, shadowing el
# global de dsh. Dos instancias de dsh-tools == dos identidades de Symbol
# distintas, y el runtime de tools deja de reconocer su propio scheduler
# ("Cannot read properties of undefined (reading 'prepare')"). Quitar la
# copia local hace que la resolución caiga al global correcto.
for pkg in dsh-tools cosmokit dsh-fs; do
  if [ -d "\$SCOPE_DIR/\$pkg" ]; then
    rm -rf "\$SCOPE_DIR/\$pkg" 2>/dev/null || true
  fi
done

exit 0
AUTOFIX_EOF
  chmod +x "$autofix_path"

  echo "escribiendo $unit_path..."
  cat > "$unit_path" <<UNIT_EOF
[Unit]
Description=DeepSeek Harness (dsh) web server
After=network.target

[Service]
Type=simple
User=$DSH_SERVICE_USER
WorkingDirectory=$DSH_MANAGE_HOME
Environment=PATH=$DSH_NODE:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=$HOME
Environment=DSH_HOME=$DSH_HOME
ExecStartPre=$autofix_path
ExecStart=$DSH_BIN web --port $DSH_PORT --no-open
Restart=always
RestartSec=3
StandardOutput=append:$DSH_LOG
StandardError=append:$DSH_LOG

[Install]
WantedBy=multi-user.target
UNIT_EOF

  systemctl daemon-reload
  systemctl enable dsh.service
  systemctl restart dsh.service
  echo "dsh.service instalado y activo. Usar 'systemctl {status,stop,restart} dsh.service' de acá en más"
  echo "(no mezclar con 'dsh-manage {start,stop}' mientras el unit esté activo — ambos gestionan el mismo puerto)"
}

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

  # El label entra en una ruta: sin validar, '../../x' escape del backup root.
  # grep (sin -z) procesa linea por linea: un label con newline embebido como
  # $'ok\n../../tmp/evil' pasa si UNA linea coincide (ok), aunque el resto no.
  # El regex nativo de bash (no multilinea) valida toda la string de una vez.
  if [[ ! "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
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

  local rc=0
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
  ) 9>"$DSH_BACKUP_ROOT/.lock" || rc=$?

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
        # head -1 hace que zstd reciba SIGPIPE; bajo pipefail eso mata el
        # pipeline aunque python3 exita. Aislamos la decodificacion en un
        # subshell con pipefail desactivado para que solo importe el rc de python3.
        ( set +o pipefail; zstd -dc "$artifact" 2>/dev/null | head -1 | python3 -c '
import json, sys
line = sys.stdin.readline()
row = json.loads(line)
assert row.get("type") == "session", row.get("type")
' >/dev/null ) 2>&1 || { echo "header ilegible: $artifact" >&2; return 1; } ;;
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
    # latest es un symlink al snapshot mas reciente: el glob */ lo expande
    # como una entrada mas (indistinguible de un dir real para [ -d ]), lo
    # que duplica ese snapshot en la salida. Saltearlo explicitamente.
    case "${dir%/}" in */latest) continue ;; esac
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
    echo "aviso: hay $partials snapshot(s) .partial de intentos incompletos; borrables a mano"
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

# Despachador de los subcomandos de session-backup.
session_backup() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    scan)     session_backup_scan "$@" ;;
    create)   session_backup_create "$@" ;;
    list)     session_backup_list "$@" ;;
    verify)   session_backup_verify "$@" ;;
    *) echo "uso: $0 session-backup {scan|create|list|verify}"; return 1 ;;
  esac
}

update() {
  stop || true
  echo "desinstalando version actual..."
  # Uninstall explicito en vez de "npm install -g pkg@latest": dsh es un RC de
  # version rapida (breaking changes esperados), y un upgrade in-place puede
  # dejar archivos viejos huerfanos si cambio el layout del paquete entre
  # versiones. Uninstall+install limpio evita esa clase de bug.
  PATH="$DSH_NODE:$PATH" npm uninstall -g --prefix "$DSH_PREFIX" @deepseek-ai/dsh || true
  echo "bajando version mas nueva..."
  install
  start
}

# Versión instalada: se lee del package.json bajo el prefix (autoritativa de
# lo que npm instaló). Si el binario existe pero falta el package.json, cae
# a `dsh --version` como fallback.
installed_version() {
  local pkg="$DSH_PREFIX/lib/node_modules/$DSH_PKG/package.json"
  if [ -f "$pkg" ]; then
    # Extraer el campo "version" sin jq (no se asume instalado).
    grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$pkg" \
      | sed -E 's/.*"([^"]+)"$/\1/'
  elif [ -x "$DSH_BIN" ]; then
    "$DSH_BIN" --version 2>/dev/null
  else
    return 1
  fi
}

# Última versión publicada en el registry. Usa cache propio (ver DSH_NPM_CACHE).
# Falla limpio (código != 0, sin output) si no hay red o npm no responde.
latest_version() {
  PATH="$DSH_NODE:$PATH" npm view "$DSH_PKG" version \
    --cache "$DSH_NPM_CACHE" 2>/dev/null | tail -1
}

# Compara instalada vs. publicada. Devuelve 0 si hay una versión más nueva
# disponible, 1 si estás al día (o igual), 2 si no se pudo determinar.
check_update_available() {
  local installed latest
  installed=$(installed_version) || return 2
  latest=$(latest_version) || return 2
  if [ -z "$installed" ] || [ -z "$latest" ]; then
    return 2
  fi
  if [ "$installed" != "$latest" ]; then
    echo "$installed -> $latest"
    return 0
  fi
  return 1
}

version() {
  local v
  v=$(installed_version) || {
    echo "dsh no instalado ($DSH_BIN no existe)"
    return 1
  }
  echo "$v"
}

check_update() {
  local installed latest
  installed=$(installed_version) || {
    echo "dsh no instalado, no hay version instalada para comparar"
    return 1
  }
  echo "instalada:  $installed"
  latest=$(latest_version) 2>/dev/null || true
  if [ -z "$latest" ]; then
    echo "no se pudo consultar el registry (sin red o npm fallo)"
    echo "instalada:  $installed"
    return 2
  fi
  echo "ultima:     $latest"
  if [ "$installed" != "$latest" ]; then
    echo "hay actualizacion disponible ($installed -> $latest)"
    echo "corre: dsh-manage update"
    return 0
  fi
  echo "estas al dia"
  return 1
}

status() {
  local existing
  existing=$(port_pid)
  if [ -n "$existing" ]; then
    echo "escuchando en :$DSH_PORT, PID $existing"
  else
    echo "nada escuchando en :$DSH_PORT"
  fi
  if [ -f "$DSH_PID" ] && [ "$(cat "$DSH_PID")" != "$existing" ]; then
    echo "pidfile stale: $(cat "$DSH_PID")"
  fi
  # Aviso breve de actualización (sin hacer ruido si no se puede consultar).
  local update_line
  if update_line=$(check_update_available); then
    echo "update disponible: $update_line (dsh-manage update)"
  fi
}

# --lib: cargar solo las funciones (para tests via `source ... --lib`), sin
# disparar el dispatcher de comandos. No es un modo de uso normal.
# shellcheck disable=SC2317  # el exit sí es alcanzable: fallback cuando se ejecuta directo (no via source)
if [ "${1:-}" = "--lib" ]; then
  return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
  start)            start ;;
  stop)             stop ;;
  update)           update ;;
  status)           status ;;
  install)          install ;;
  plugins-install)  plugins_install "${2:-}" ;;
  service-install)  service_install ;;
  session-backup)   session_backup "${@:2}" ;;
  version)          version ;;
  check-update)     check_update ;;
  --version|-V)     echo "dsh-manage v$DSH_MANAGE_VERSION" ;;
  *) echo "uso: $0 {start|stop|update|status|install|plugins-install [profile]|service-install|session-backup {scan}|version|check-update}"; exit 1 ;;
esac
