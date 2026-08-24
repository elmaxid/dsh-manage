#!/usr/bin/env bash
#
# install.sh — instalador de dsh-manage para puestos de desarrollo.
#
# Clona (o actualiza) el repo completo en $CLONE_DIR (default ~/.dsh-manage)
# y deja $PREFIX/dsh-manage (default /usr/local/bin/dsh-manage) como symlink
# al script principal dentro del clon. El repo completo hace falta de
# verdad: `dsh-manage plugins-install` resuelve plugins/manifest.json y los
# patches por ruta relativa al propio script — bajar solo dsh-manage.sh
# suelto (como hacía una versión anterior de este instalador) deja
# plugins-install sin encontrar el manifest. No instala DSH en sí: eso lo
# hace después `dsh-manage install`.
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
#   --prefix <dir>   dir del symlink ejecutable (default: /usr/local/bin)
#   --clone-dir <dir> dir del repo clonado (default: ~/.dsh-manage)
#   --ref <git-ref>  versión/branch/tag a bajar (default: main)
#   --no-color       desactivar colores
#   -h, --help       esta ayuda

set -euo pipefail

REPO="elmaxid/dsh-manage"
REPO_URL="https://github.com/${REPO}.git"
PREFIX="/usr/local/bin"
CLONE_DIR="${HOME}/.dsh-manage"
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
  --prefix <dir>   dir del symlink ejecutable (default: /usr/local/bin)
  --clone-dir <dir> dir del repo clonado (default: ~/.dsh-manage)
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
      --clone-dir) CLONE_DIR="${2:-}"; [ -n "$CLONE_DIR" ] || die "--clone-dir requiere un valor"; shift 2 ;;
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
  printf '%sClona el repo %s y deja dsh-manage en %s%s\n' "$C_DIM" "$REPO" "$PREFIX" "$C_RESET"
  printf '%sNO instala DSH en sí; eso lo hacés después con: dsh-manage install%s\n\n' "$C_DIM" "$C_RESET"
}

plan() {
  printf '%sPlan:%s\n' "$C_BOLD" "$C_RESET"
  printf '  1. Clonar (o actualizar) %s%s%s\n' "$C_BOLD" "$CLONE_DIR" "$C_RESET"
  printf '  2. Dejar %s%s/dsh-manage%s como symlink a %s/dsh-manage.sh\n' "$C_BOLD" "$PREFIX" "$C_RESET" "$CLONE_DIR"
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

# Detección de herramientas: además de curl/wget (para el one-liner que nos
# baja) necesitamos git (para clonar el repo completo).
have_git() {
  if ! have git; then
    die "necesito git para clonar el repo completo de dsh-manage"
  fi
}

clone_or_update() {
  if [ -d "$CLONE_DIR/.git" ]; then
    info "repo ya existe en $CLONE_DIR — actualizando a ref $REF..."
    (cd "$CLONE_DIR" && git fetch --quiet --tags origin && git checkout --quiet "$REF" && git pull --quiet --ff-only origin "$REF") \
      || die "no se pudo actualizar $CLONE_DIR"
    ok "actualizado a $REF"
  else
    info "clonando $REPO en $CLONE_DIR..."
    verbose "ejecutando: git clone --quiet $REPO_URL $CLONE_DIR"
    git clone --quiet "$REPO_URL" "$CLONE_DIR" || die "no se pudo clonar $REPO_URL"
    if [ "$REF" != "main" ]; then
      (cd "$CLONE_DIR" && git checkout --quiet "$REF") || die "ref $REF no existe"
    fi
    ok "clonado en $CLONE_DIR"
  fi
}

install_script() {
  local src="$CLONE_DIR/dsh-manage.sh"
  local dest="$PREFIX/dsh-manage"
  [ -f "$src" ] || die "el clon no contiene dsh-manage.sh (¿está en $REF?)"
  info "symlink: $dest -> $src"
  verbose "ejecutando: $SUDO ln -sf $src $dest"
  $SUDO ln -sf "$src" "$dest"
  $SUDO chmod 755 "$src"
  ok "instalado: $dest"
}

next_steps() {
  printf '\n%sListo.%s Para empezar (con el repo completo ya disponible):\n' "$C_GREEN" "$C_RESET"
  printf '  %sdsh-manage install%s            # instala @deepseek-ai/dsh\n' "$C_BOLD" "$C_RESET"
  printf '  %sdsh-manage plugins-install%s    # stack de ~19 plugins homologado\n' "$C_BOLD" "$C_RESET"
  printf '  %sdsh-manage service-install%s    # watchdog systemd\n' "$C_BOLD" "$C_RESET"
  printf '  %sdsh-manage status%s             # ver estado + update disponible\n' "$C_BOLD" "$C_RESET"
  printf '\n'
}

main() {
  parse_args "$@"
  setup_colors
  banner
  plan
  pick_fetcher
  have_git
  maybe_sudo
  confirm
  clone_or_update
  install_script
  next_steps
}

main "$@"