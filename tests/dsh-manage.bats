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
