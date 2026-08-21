#!/usr/bin/env bash
#
# install.sh — instalador de dsh-manage para puestos de desarrollo.
#
# Baja dsh-manage.sh del repo de GitHub y lo deja en $PREFIX (default
# /usr/local/bin/dsh-manage) con permisos de ejecución. No instala DSH en sí:
# eso lo hace después `dsh-manage install`.
#
# Uso (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh | bash
#
# Otra vía (recomendada, para inspeccionar antes de ejecutar):
#   curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh -o install.sh
#   less install.sh        # revisar
#   bash install.sh
#
# Opciones:
#   -y, --yes        no preguntar confirmación (asume sí)
#   -v, --verbose    mostrar cada paso en detalle
#   --prefix <dir>   dir de instalación (default: /usr/local/bin)
#   --ref <git-ref>  versión/branch/tag a bajar (default: main)
#   --no-color       desactivar colores
#   -h, --help       esta ayuda

set -euo pipefail

REPO="elmaxid/dsh-manage"
RAW_BASE="https://raw.githubusercontent.com/${REPO}"
SCRIPT_NAME="dsh-manage.sh"
PREFIX="/usr/local/bin"
REF="main"
YES=0
VERBOSE=0
NO_COLOR=0

# Defaults vacíos para que err()/die() no crasheen con `set -u` si se llama
# antes de setup_colors() (ej. parse_args con una opción inválida).
C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_DIM=""

# ── Colores (con detección de TTY y NO_COLOR) ─────────────────────────────
setup_colors() {
  if [ "$NO_COLOR" -eq 1 ]; then
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_DIM=""
    return
  fi
  if [ ! -t 1 ] || [ "${NO_COLOR:-}" = "1" ]; then
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_DIM=""
    return
  fi
  C_RESET=$'\033[0m';   C_BOLD=$'\033[1m'
  C_RED=$'\033[31m';    C_GREEN=$'\033[32m';  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m';   C_CYAN=$'\033[36m';   C_DIM=$'\033[2m'
}

# ── Logging ───────────────────────────────────────────────────────────────
say()    { printf '%s\n' "$*"; }
info()   { printf '%s%s%s %s\n' "$C_BLUE" "►" "$C_RESET" "$*"; }
ok()     { printf '%s%s%s %s\n' "$C_GREEN" "✓" "$C_RESET" "$*"; }
warn()   { printf '%s%s%s %s\n' "$C_YELLOW" "!" "$C_RESET" "$*" >&2; }
err()    { printf '%s%s%s %s\n' "$C_RED" "✗" "$C_RESET" "$*" >&2; }
die()    { err "$*"; exit 1; }
verbose(){ if [ "$VERBOSE" -eq 1 ]; then printf '%s%s%s %s\n' "$C_DIM" "·" "$C_RESET" "$*"; fi; }

# ── Args ──────────────────────────────────────────────────────────────────
show_help() {
  sed -n '3,/^$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
  cat <<EOF

Opciones:
  -y, --yes        no preguntar confirmación
  -v, --verbose    mostrar cada paso en detalle
  --prefix <dir>   dir de instalación (default: /usr/local/bin)
  --ref <git-ref>  versión/branch/tag a bajar (default: main)
  --no-color       desactivar colores
  -h, --help       esta ayuda
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)    YES=1; shift ;;
      -v|--verbose)VERBOSE=1; shift ;;
      --prefix)    PREFIX="${2:-}"; [ -n "$PREFIX" ] || die "--prefix requiere un valor"; shift 2 ;;
      --ref)       REF="${2:-}";    [ -n "$REF" ]    || die "--ref requiere un valor"; shift 2 ;;
      --no-color)  NO_COLOR=1; shift ;;
      -h|--help)   show_help; exit 0 ;;
      *) die "opcion desconocida: $1 (usa --help)" ;;
    esac
  done
}

# ── Detección de herramientas ─────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

pick_fetcher() {
  if have curl; then
    FETCH="curl -fsSL"
  elif have wget; then
    FETCH="wget -qO-"
  else
    die "necesito curl o wget para bajar el script"
  fi
  verbose "fetcher: $FETCH"
}

# Sudo solo si no somos root y el destino no es escribible sin él.
maybe_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    verbose "corriendo como root, sin sudo"
  elif [ -w "$PREFIX" ] 2>/dev/null; then
    SUDO=""
    verbose "PREFIX escribible sin sudo"
  elif have sudo; then
    SUDO="sudo"
    verbose "usando sudo para escribir en $PREFIX"
  else
    die "no soy root, $PREFIX no es escribible y no hay sudo"
  fi
}

# ── Instalación ───────────────────────────────────────────────────────────
banner() {
  printf '\n'
  printf '%s%sdsh-manage — instalador%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '%sBaja el script dsh-manage.sh del repo %s y lo instala%s\n' "$C_DIM" "$REPO" "$C_RESET"
  printf '%sNO instala DSH en sí; eso lo hacés después con: dsh-manage install%s\n\n' "$C_DIM" "$C_RESET"
}

plan() {
  printf '%sPlan:%s\n' "$C_BOLD" "$C_RESET"
  printf '  1. Bajar %s/%s/%s\n' "$RAW_BASE" "$REF" "$SCRIPT_NAME"
  printf '  2. Verificar que es un script bash válido\n'
  printf '  3. Instalar en %s%s/dsh-manage%s (permisos 755)\n' "$C_BOLD" "$PREFIX" "$C_RESET"
  printf '\n'
}

confirm() {
  if [ "$YES" -eq 1 ]; then
    verbose "—yes dado, salteando confirmación"
    return 0
  fi
  printf '%s¿Continuar? [s/N] %s' "$C_YELLOW" "$C_RESET"
  local resp
  read -r resp
  case "$resp" in
    s|S|y|Y) return 0 ;;
    *) warn "abortado por el usuario"; exit 130 ;;
  esac
}

fetch_script() {
  local url="$RAW_BASE/$REF/$SCRIPT_NAME"
  info "bajando $url"
  verbose "ejecutando: $FETCH \"$url\""
  content=$($FETCH "$url") || die "no se pudo bajar $url"
  [ -n "$content" ] || die "la respuesta vino vacía (¿ref incorrecto?: $REF)"
  # Sanity: debe empezar con shebang bash. Evita instalar algo que no es el script.
  case "$content" in
    "#!/usr/bin/env bash"*) : ;;
    *) die "el contenido bajado no empieza con shebang bash — abortando por seguridad" ;;
  esac
  verbose "descargado $(printf '%s' "$content" | wc -l) líneas, shebang OK"
}

install_script() {
  local dest="$PREFIX/dsh-manage"
  info "instalando en $dest"
  verbose "escribiendo contenido con $SUDO"
  printf '%s\n' "$content" | $SUDO tee "$dest" >/dev/null
  $SUDO chmod 755 "$dest"
  ok "instalado: $dest"
}

next_steps() {
  printf '\n%sListo.%s Para empezar:\n' "$C_GREEN" "$C_RESET"
  printf '  %sdsh-manage install%s   # instala @deepseek-ai/dsh\n' "$C_BOLD" "$C_RESET"
  printf '  %sdsh-manage start%s     # arranca el servidor\n' "$C_BOLD" "$C_RESET"
  printf '  %sdsh-manage status%s    # ver estado + update disponible\n' "$C_BOLD" "$C_RESET"
  printf '\n'
}

main() {
  parse_args "$@"
  setup_colors
  banner
  plan
  pick_fetcher
  maybe_sudo
  confirm
  fetch_script
  install_script
  next_steps
}

main "$@"