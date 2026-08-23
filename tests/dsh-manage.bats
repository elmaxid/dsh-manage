#!/usr/bin/env bats

# Tests de dsh-manage.sh. Miden el comportamiento visible del script usando
# un puerto falso para no tocar una instalacion real de DSH ni el puerto 3080.
# No ejecutan install/start/update reales (eso instalaria paquetes y subiria
# un servidor); los casos cubren la logica pura (argumentos, status, parseo).

setup() {
  export DSH_HOME="$BATS_TEST_TMPDIR/home"
  export DSH_NODE="$BATS_TEST_TMPDIR/bin"
  export TEST_PORT="${TEST_PORT:-39991}"
  mkdir -p "$DSH_HOME" "$DSH_NODE"
}

@test "sin argumentos imprime uso y falla" {
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uso:"* ]]
  [[ "$output" == *"plugins-install"* ]]
  [[ "$output" == *"service-install"* ]]
}

@test "comando invalido imprime uso y falla" {
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"uso:"* ]]
}

@test "status sin nada escuchando reporta nada" {
  DSH_PORT="$TEST_PORT" run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada escuchando en :$TEST_PORT"* ]]
}

@test "crea DSH_HOME al ejecutar status" {
  DSH_PORT="$TEST_PORT" run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" status
  [ -d "$DSH_HOME" ]
}

@test "version sin instalar reporta que falta y falla" {
  # DSH_NODE apunta a un dir vacio: ni binario ni package.json existen.
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" version
  [ "$status" -ne 0 ]
  [[ "$output" == *"no instalado"* ]]
}

@test "check-update sin instalar reporta que falta" {
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" check-update
  [ "$status" -ne 0 ]
  [[ "$output" == *"no instalado"* ]]
}

@test "node_available detecta node ausente" {
  # DSH_NODE apunta a un dir vacio (setup): no hay binario node.
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && node_available"
  [ "$status" -ne 0 ]
}

@test "node_available detecta node presente" {
  # Simular un binario node ejecutable en DSH_NODE.
  printf '#!/bin/sh\necho v24.0.0\n' > "$DSH_NODE/node"
  chmod +x "$DSH_NODE/node"
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && node_available"
  [ "$status" -eq 0 ]
}

@test "node_download_url arma una URL valida por arquitectura" {
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && node_download_url v24.19.0 x86_64"
  [ "$status" -eq 0 ]
  [[ "$output" == "https://nodejs.org/dist/v24.19.0/node-v24.19.0-linux-x64.tar.xz" ]]
}

@test "node_download_url mapea aarch64 a arm64" {
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && node_download_url v24.19.0 aarch64"
  [ "$status" -eq 0 ]
  [[ "$output" == "https://nodejs.org/dist/v24.19.0/node-v24.19.0-linux-arm64.tar.xz" ]]
}

@test "node_download_url rechaza arquitectura desconocida" {
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && node_download_url v24.19.0 sparc64"
  [ "$status" -ne 0 ]
}

@test "start hace bootstrap de node si no esta antes de instalar" {
  # DSH_NODE vacio: start() deberia intentar bootstrap_node antes de install().
  # No hay red real en el test -> bootstrap_node falla, pero el mensaje de
  # intento debe aparecer (confirma que se llama, no que se salteo).
  DSH_PORT="$TEST_PORT" DSH_START_TIMEOUT=1 run timeout 5 bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" start
  [[ "$output" == *"node no encontrado"* ]] || [[ "$output" == *"bootstrap"* ]] || [[ "$output" == *"descargando node"* ]]
}

@test "--version imprime la version del propio script (semver)" {
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^dsh-manage\ v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "-V es alias de --version" {
  run bash "$BATS_TEST_DIRNAME/../dsh-manage.sh" -V
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^dsh-manage\ v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "DSH_MANAGE_VERSION esta definida y es semver valido" {
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && echo \"\$DSH_MANAGE_VERSION\""
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "dsh_service_manages_this_home es false sin dsh.service o si no coincide el WorkingDirectory" {
  # Regresión: plugins_install() reinició por error el dsh.service del HOST
  # (homónimo, gestionando otro DSH_HOME) al correr contra un profile de
  # scratch con DSH_HOME distinto -- verificar identidad real, no solo que
  # el nombre del unit exista.
  DSH_HOME="$BATS_TEST_TMPDIR/otro-home-que-no-coincide" run bash -c "
    export DSH_HOME='$BATS_TEST_TMPDIR/otro-home-que-no-coincide'
    source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && dsh_service_manages_this_home
  "
  [ "$status" -ne 0 ]
}

@test "pnpm_available detecta pnpm ausente" {
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && pnpm_available"
  [ "$status" -ne 0 ]
}

@test "pnpm_available detecta pnpm presente" {
  printf '#!/bin/sh\necho 11.0.0\n' > "$DSH_NODE/pnpm"
  chmod +x "$DSH_NODE/pnpm"
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && pnpm_available"
  [ "$status" -eq 0 ]
}

@test "plugins_install falla si dsh no esta instalado" {
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && plugins_install web"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no instalado"* ]]
}

@test "plugins_install falla si el manifest no existe" {
  # Simular dsh instalado (basta con que el binario exista y sea ejecutable)
  mkdir -p "$(dirname "$(dirname "$DSH_NODE")")"
  printf '#!/bin/sh\nexit 0\n' > "$DSH_NODE/dsh"
  chmod +x "$DSH_NODE/dsh"
  DSH_MANIFEST="$BATS_TEST_TMPDIR/no-existe.json" run bash -c "
    export DSH_MANIFEST='$BATS_TEST_TMPDIR/no-existe.json'
    source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && plugins_install web
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest no encontrado"* ]]
}

@test "manifest.json del stack de plugins es JSON valido" {
  run python3 -c "import json; json.load(open('$BATS_TEST_DIRNAME/../plugins/manifest.json'))"
  [ "$status" -eq 0 ]
}

@test "manifest.json no incluye dsh-doublecheck en dependencies" {
  run python3 -c "
import json
m = json.load(open('$BATS_TEST_DIRNAME/../plugins/manifest.json'))
assert 'dsh-doublecheck' not in m['dependencies'], 'dsh-doublecheck no deberia estar en dependencies (incompatible)'
"
  [ "$status" -eq 0 ]
}

@test "manifest.json declara los 3 patches con archivo .patch presente" {
  run python3 -c "
import json, os
base = '$BATS_TEST_DIRNAME/../plugins'
m = json.load(open(base + '/manifest.json'))
for spec, path in m['patchedDependencies'].items():
    full = os.path.join(base, path)
    assert os.path.isfile(full), f'falta el archivo de patch: {full} (declarado para {spec})'
"
  [ "$status" -eq 0 ]
}

@test "merge-package-json.mjs es idempotente contra un package.json ya completo" {
  cp "$BATS_TEST_DIRNAME/../plugins/manifest.json" "$BATS_TEST_TMPDIR/manifest.json"
  node "$BATS_TEST_DIRNAME/../plugins/merge-package-json.mjs" \
    "$BATS_TEST_TMPDIR/no-existe.json" "$BATS_TEST_TMPDIR/manifest.json" web > "$BATS_TEST_TMPDIR/pkg1.json"
  node "$BATS_TEST_DIRNAME/../plugins/merge-package-json.mjs" \
    "$BATS_TEST_TMPDIR/pkg1.json" "$BATS_TEST_TMPDIR/manifest.json" web > "$BATS_TEST_TMPDIR/pkg2.json"
  run diff "$BATS_TEST_TMPDIR/pkg1.json" "$BATS_TEST_TMPDIR/pkg2.json"
  [ "$status" -eq 0 ]
}

@test "merge-package-json.mjs preserva un dependency existente en vez de pisarlo" {
  cat > "$BATS_TEST_TMPDIR/existing.json" <<'EOF'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": { "dsh-context": "0.1.0-custom" },
  "dsh": { "profile": { "bundles": ["dsh-context"] } }
}
EOF
  run node "$BATS_TEST_DIRNAME/../plugins/merge-package-json.mjs" \
    "$BATS_TEST_TMPDIR/existing.json" "$BATS_TEST_DIRNAME/../plugins/manifest.json" web
  [ "$status" -eq 0 ]
  [[ "$output" == *'"dsh-context": "0.1.0-custom"'* ]]
}

@test "merge-pnpm-workspace.py es idempotente contra un pnpm-workspace.yaml ya completo" {
  python3 "$BATS_TEST_DIRNAME/../plugins/merge-pnpm-workspace.py" \
    /dev/null "$BATS_TEST_DIRNAME/../plugins/manifest.json" > "$BATS_TEST_TMPDIR/ws1.yaml"
  python3 "$BATS_TEST_DIRNAME/../plugins/merge-pnpm-workspace.py" \
    "$BATS_TEST_TMPDIR/ws1.yaml" "$BATS_TEST_DIRNAME/../plugins/manifest.json" > "$BATS_TEST_TMPDIR/ws2.yaml"
  run diff "$BATS_TEST_TMPDIR/ws1.yaml" "$BATS_TEST_TMPDIR/ws2.yaml"
  [ "$status" -eq 0 ]
}

@test "merge-pnpm-workspace.py no fuerza better-sqlite3 a compilar" {
  run python3 "$BATS_TEST_DIRNAME/../plugins/merge-pnpm-workspace.py" \
    /dev/null "$BATS_TEST_DIRNAME/../plugins/manifest.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"better-sqlite3: false"* ]]
}

@test "service_install requiere root" {
  # bats-core corre como el usuario del CI runner (no root); si CI corriera
  # como root este test se saltea porque no puede simular "no ser root".
  if [ "$(id -u)" -eq 0 ]; then
    skip "corriendo como root, no se puede probar el rechazo por no-root"
  fi
  run bash -c "source '$BATS_TEST_DIRNAME/../dsh-manage.sh' --lib && service_install"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requiere root"* ]]
}
