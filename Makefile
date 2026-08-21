SHELL := /bin/bash

SCRIPT   := dsh-manage.sh
BATS_BIN := $(shell command -v bats 2>/dev/null)

.PHONY: check test bats install-bats

## check: sintaxis + shellcheck (si esta instalado)
check:
	@echo "==> bash -n $(SCRIPT)"
	@bash -n $(SCRIPT)
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "==> shellcheck $(SCRIPT) tests/"; \
		shellcheck $(SCRIPT) tests/*.bats; \
	else \
		echo "shellcheck no esta instalado, saltando (instala con: sudo apt install shellcheck)"; \
	fi

## bats: correr la bateria de tests (requiere bats-core)
bats: SHELL := /bin/bash
bats:
	@if command -v bats >/dev/null 2>&1; then \
		bats tests; \
	else \
		echo "bats no esta instalado. Hace: make install-bats"; exit 1; \
	fi

test: check bats

## install-bats: instala bats-core desde GitHub
install-bats:
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "instalando bats-core en ~/.local..."; \
		git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core && \
		/tmp/bats-core/install.sh "$(HOME)/.local" && \
		echo "bats instalado. Agrega $(HOME)/.local/bin a tu PATH."; \
	else \
		echo "bats ya instalado: $$(command -v bats)"; \
	fi
