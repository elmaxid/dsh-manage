# Desplegar DSH + plugins en un server dev nuevo

Guía para levantar un segundo puesto de desarrollo idéntico a este, usando el
flujo de instalación propio del repo. Verificada contra el server de origen
(2026-08-28): DSH 0.1.1-rc.2, Node 24, perfil `web` con 31 plugins.

## Requisitos previos

- Debian/Ubuntu con `curl`, `git` y acceso root (o sudo).
- Acceso de red al endpoint de modelos (en este despliegue `http://10.50.1.67:4000/v1`).
- Credenciales GitHub con acceso a `elmaxid/dsh-manage` (repo privado).
- La API key del provider, exportable como variable de entorno (ver settings).

## 1. Instalar dsh-manage (el instalador del repo)

```bash
curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh -o install.sh
less install.sh        # revisar antes de ejecutar
bash install.sh
```

Clona el repo en `~/.dsh-manage` y deja `dsh-manage` en `/usr/local/bin`.

## 2. Instalar DSH

```bash
dsh-manage install
```

Bootstrap de Node 24 + `npm install -g @deepseek-ai/dsh` (con allow-scripts
solo para los addons homologados).

## 3. Instalar el stack homologado de plugins

```bash
dsh-manage plugins-install web
```

Instala los 25 plugins npm de `plugins/manifest.json` (con gate de resguardo
de sesiones y patches aplicados). **No cubre** (ver §6): `dsh-model-sync`,
los 4 plugins de GitHub y `dsh-doublecheck`.

## 4. Servicio systemd + arranque

```bash
dsh-manage service-install
systemctl enable --now dsh
systemctl status dsh
```

En el server de origen la unidad corre `dsh web` con
`ExecStartPre=/root/dsh-test/dsh-autofix.sh`, logs en
`/root/dsh-test/dsh.log`. Copiar `dsh-autofix.sh` desde el server de origen
(`/root/dsh-test/`) o ajustar la unidad.

GUI en `http://<server>:3080`.

## 5. Configuración del provider (settings.yaml)

Copiar del server de origen `/root/.dsh/settings.yaml` los bloques que
conectan con el endpoint — estructura actual:

```yaml
llm-pi-ai:
  providers:
    ollama-mke:
      displayName: ...
      apiKeyEnv: <NOMBRE_DE_VARIABLE>   # el valor va por entorno, no en el yaml
      api: openai-completions
      baseURL: http://10.50.1.67:4000/v1
      models: [ ... ]                   # 41 entradas; se puede sincronizar después
agent-default-model:
  provider: ollama-mke
  model: glm-5.3-zai
locale:
  preference: en
agent-presets:
  default: cordis
```

Exportar la variable de la API key en el entorno del servicio (unit de systemd
o `/root/.dsh` según cómo lo resuelva el adaptador) y reiniciar.

Alternativa recomendada: arrancar con `models: []` para el provider y usar el
tab **Modelos** de `dsh-model-sync` para poblar el catálogo desde el endpoint
(con preview y protecciones) — es justo lo que hace el plugin.

## 6. Lo que `plugins-install` NO cubre

### dsh-model-sync (tarball local, vive en este repo)

El plugin se desarrolla en `dsh-model-sync/` del repo y se empaqueta como
tarball (`*.tgz` está gitignoreado). En el server nuevo, con el repo ya clonado
por `install.sh`:

```bash
cd ~/.dsh-manage/dsh-model-sync
pnpm install --ignore-scripts
pnpm run verify        # 37 tests + typechecks + build
pnpm pack
dsh plugin --profile web add ./dsh-model-sync-0.1.0.tgz
```

Requiere Node ≥ 22.19 (el mismo node24 del bootstrap) y pnpm
(`corepack enable` o `npm i -g pnpm`).

### 4 plugins de GitHub (opcionales, presentes en el origen)

```bash
dsh plugin --profile web add github:Nagi-ovo/dsh-visualize
dsh plugin --profile web add github:01Virex/dsh-status-rotator
dsh plugin --profile web add github:dat-lequoc/dsh-subagent-model
dsh plugin --profile web add github:stephenlzc/dsh-swarm-panel#path:dsh-swarm-plugin
```

Nota: el `dsh-kimicode-swarm` del manifest espera el patch
`plugins/patches/dsh-kimicode-swarm@0.1.0.patch` (fix de `provider:undefined`
en overrides de modelo y dark mode); `plugins-install` lo aplica del repo.

### dsh-doublecheck

Instalado en el origen (`^0.7.1`) pero ausente del manifest. Agregarlo al
manifest o instalarlo a mano:

```bash
dsh plugin --profile web add dsh-doublecheck@^0.7.1
```

## 7. Verificación post-instalación

```bash
dsh-manage status                                   # estado + updates
dsh --profile web --dump-config | grep dsh-model-sync   # fila montada
cd <plugin>/node_modules/dsh-model-sync && node -e "import('dsh-model-sync').then(m=>console.log('host OK',m.name))"
```

En el GUI: abrir una conversación → tab **Modelos** → **Buscar modelos** →
debe listar el diff contra el endpoint. El default del host y el modelo de la
sesión activa aparecen como **Protegidos**.

## Mantenimiento

```bash
dsh-manage update            # actualiza el repo + DSH según su flujo
dsh plugin --profile web remove <nombre>   # desinstalar un plugin
```

Backup del manifiesto del perfil antes de cambios grandes:
`cp ~/.dsh/profiles/web/package.json ~/web-package.json.bak` (patrón usado en
el origen para garantizar que ningún plugin se pierde en un add/re-add).
