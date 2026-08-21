# dsh-manage

Instalación y administración de **DeepSeek Harness (dsh)** desde la línea de
comandos. Controla el ciclo de vida del servidor web de DSH — instalar,
iniciar, detener, actualizar y consultar estado — de forma idempotente y
robusta.

Pensado para replicarse en los puestos de desarrollo y operar sobre una
instalación de DSH aislada en la tree de `node24` del usuario.

## Comandos

| Comando   | Qué hace                                                                 |
|-----------|--------------------------------------------------------------------------|
| `install` | Instala `@deepseek-ai/dsh` globalmente en la tree de `node24`            |
| `start`   | Arranca el servidor web si no está escuchando ya (idempotente)           |
| `stop`    | Detiene el proceso que escucha el puerto                                  |
| `update`  | `uninstall` + `install` limpio de la última versión y lo deja corriendo   |
| `status`  | Muestra si algo escucha el puerto y si el pidfile quedó stale             |

```
dsh-manage start
dsh-manage status
dsh-manage update
dsh-manage stop
```

## Requisitos

- **Linux** con `ss` (iproute2) y `npm`.
- **Correr como el usuario que posee el proceso de DSH** (normalmente `root`):
  la detección de PID usa `ss -ltnp`, que solo expone los pids de los sockets
  sobre los que se tienen permisos.

## Instalación

Como el proyecto se versiona en el repo, la vía más simple es copiar el script
a un lugar del `PATH` en cada puesto:

```bash
sudo cp dsh-manage.sh /usr/local/bin/dsh-manage
sudo chmod +x /usr/local/bin/dsh-manage
```

Alternativamente, operar directo desde el repo: `./dsh-manage.sh <comando>`.

## Configuración

Todo tiene defaults razonables y se overridea por variables de entorno:

| Variable            | Default                                | Descripción                            |
|---------------------|----------------------------------------|----------------------------------------|
| `DSH_NODE`          | `$HOME/.local/dsh-node/node24/bin`     | Dir de los binarios node/npm/dsh        |
| `DSH_HOME`          | `$HOME/dsh-test`                       | Dir de trabajo, log y pidfile           |
| `DSH_PORT`          | `3080`                                 | Puerto donde escucha DSH                |
| `DSH_START_TIMEOUT` | `180`                                  | Segundos a esperar por el puerto        |
| `DSH_ALLOW_SCRIPTS` | lista de addons nativos de dsh          | Paquetes a los que npm permite scripts  |

Ejemplo con otro home y puerto:

```bash
DSH_HOME=/srv/dsh DSH_PORT=3100 dsh-manage start
```

## Cómo funciona

- **El puerto es la autoridad**, no el pidfile. `port_pid()` lee con `ss`
  quién está escuchando en `DSH_PORT`. Un pidfile por sí solo no prueba que
  DSH esté corriendo: tras un reboot o crash el PID puede ser reutilizado
  por otro proceso. El pidfile es solo limpieza extra.
- **Instalación aislada**: `npm install -g --prefix` scoped a la tree de
  `node24`, overrideando por comando el `prefix` fijado en el `~/.npmrc` del
  usuario (que apunta a un Node del sistema demasiado viejo para dsh y que
  comparte otro servicio). Así no se toca la config compartida.
- **Addons nativos**: `koffi`, `node-pty` y demás traen addons que el guard
  de scripts de npm bloquea salvo que se listen explícitamente con
  `--allow-scripts`.
- **Actualización limpia**: `update` hace `uninstall` + `install` explícitos
  en vez de un upgrade in-place, porque dsh es un RC de versionado rápido
  (breaking changes esperados) y un in-place puede dejar archivos huérfanos.

## Desarrollo

```sh
make check    # bash -n + shellcheck (si está instalado)
make test     # batería de tests con bats-core
```

El CI corre `bash -n`, `shellcheck` y la batería de `bats` en cada push.

## Licencia

[MIT](LICENSE)
