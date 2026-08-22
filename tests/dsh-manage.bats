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
  [[ "$output" == *"start|stop|update|status|install|version|check-update"* ]]
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
