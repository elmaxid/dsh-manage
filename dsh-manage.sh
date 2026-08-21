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
#
# Requiere correr como el usuario que posee el proceso de DSH (normalmente
# root). port_pid() depende de que `ss` pueda leer los pids de los sockets,
# lo que exige permisos sobre el proceso en cuestión.
#
# Variables de entorno (con defaults razonables):
#   DSH_NODE          dir del binario node/npm/dsh (default: node24 tree)
#   DSH_HOME          directorio de trabajo y de logs
#   DSH_PORT          puerto donde DSH escucha (default: 3080)
#   DSH_START_TIMEOUT segundos a esperar por el puerto (default: 180)
#   DSH_ALLOW_SCRIPTS paquetes con addons nativos a los que npm permite scripts
#   DSH_PKG           nombre del paquete npm (default: @deepseek-ai/dsh)
#   DSH_NPM_CACHE     cache de npm para consultas (default: $DSH_HOME/.npm-cache)

set -euo pipefail

DSH_NODE="${DSH_NODE:-$HOME/.local/dsh-node/node24/bin}"
DSH_HOME="${DSH_HOME:-$HOME/dsh-test}"
DSH_LOG="$DSH_HOME/dsh.log"
DSH_PID="$DSH_HOME/dsh.pid"
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
# cache scoped a DSH_HOME evita chocar con el cache compartido.
DSH_NPM_CACHE="${DSH_NPM_CACHE:-$DSH_HOME/.npm-cache}"

mkdir -p "$DSH_HOME"

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

install() {
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
  cd "$DSH_HOME"
  # Binario instalado (no via npx): el proceso que arranca ES el que escucha
  # el puerto. stop() igual mata por PID del puerto, que es lo autoritativo.
  PATH="$DSH_NODE:$PATH" nohup "$DSH_BIN" web > "$DSH_LOG" 2>&1 &
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

case "${1:-}" in
  start)        start ;;
  stop)         stop ;;
  update)       update ;;
  status)       status ;;
  install)      install ;;
  version)      version ;;
  check-update) check_update ;;
  *) echo "uso: $0 {start|stop|update|status|install|version|check-update}"; exit 1 ;;
esac
