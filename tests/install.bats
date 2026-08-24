#!/usr/bin/env bats

# Tests de install.sh. Solo cubren lógica pura (args/help) sin tocar red ni
# instalar nada: los casos de red se dejan para verificación manual/CI externa.

@test "install.sh --help imprime ayuda y termina OK" {
  run bash "$BATS_TEST_DIRNAME/../install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"--verbose"* ]]
  [[ "$output" == *"--prefix"* ]]
}

@test "install.sh opcion invalida falla" {
  run bash "$BATS_TEST_DIRNAME/../install.sh" --no-existe
  [ "$status" -ne 0 ]
  [[ "$output" == *"opcion desconocida"* ]]
}

@test "install.sh --prefix sin valor falla" {
  run bash "$BATS_TEST_DIRNAME/../install.sh" --prefix
  [ "$status" -ne 0 ]
  [[ "$output" == *"--prefix requiere un valor"* ]]
}
@test "install.sh --help menciona --clone-dir" {
  run bash "$BATS_TEST_DIRNAME/../install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--clone-dir"* ]]
}

@test "install.sh --clone-dir sin valor falla" {
  run bash "$BATS_TEST_DIRNAME/../install.sh" --clone-dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"--clone-dir requiere un valor"* ]]
}
