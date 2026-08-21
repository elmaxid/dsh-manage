# dsh-manage

Instalación y administración de **DeepSeek Harness (dsh)** desde la línea de
comandos. Controla el ciclo de vida del servidor web de DSH — instalar,
iniciar, detener, actualizar y consultar estado — de forma idempotente y
robusta.

Pensado para replicarse en los puestos de desarrollo y operar sobre una
instalación de DSH aislada en la tree de `node24` del usuario.

## Comandos

| Comando        | Qué hace                                                                 |
|----------------|--------------------------------------------------------------------------|
| `install`      | Instala `@deepseek-ai/dsh` globalmente en la tree de `node24`            |
| `start`        | Arranca el servidor web si no está escuchando ya (idempotente)           |
| `stop`         | Detiene el proceso que escucha el puerto                                  |
| `update`       | `uninstall` + `install` limpio de la última versión y lo deja corriendo   |
| `status`       | Muestra si algo escucha el puerto, pidfile stale y avisa si hay update    |
| `version`      | Muestra la versión instalada                                              |
| `check-update` | Compara la versión instalada vs. la última publicada en npm               |

```
dsh-manage start
dsh-manage status
dsh-manage version
dsh-manage check-update
dsh-manage update
dsh-manage stop
```

### `check-update` y `status`

`check-update` consulta el registry de npm y dice si hay una versión más nueva:

```
instalada:  0.1.1-rc.2
ultima:     0.1.1-rc.3
hay actualizacion disponible (0.1.1-rc.2 -> 0.1.1-rc.3)
corre: dsh-manage update
```

- Sin red o si npm no responde → reporta que no pudo consultar (no falla el script).
- `status` incluye un aviso breve de update disponible, sin hacer ruido si estás al día o sin red.

## Requisitos

- **Linux** con `ss` (iproute2) y `npm`.
- **Correr como el usuario que posee el proceso de DSH** (normalmente `root`):
  la detección de PID usa `ss -ltnp`, que solo expone los pids de los sockets
  sobre los que se tienen permisos.

## Instalación

### One-liner (recomendado para puestos dev)

Baja `dsh-manage.sh` del repo y lo deja en `/usr/local/bin/dsh-manage`:

```bash
curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh | bash
```

El instalador muestra el plan, verifica que lo bajado sea un script bash válido
(shebang) y pide confirmación antes de instalar. Opciones:

| Flag              | Qué hace                                            |
|-------------------|-----------------------------------------------------|
| `-y, --yes`       | No pedir confirmación                               |
| `-v, --verbose`   | Mostrar cada paso en detalle                         |
| `--prefix <dir>`  | Dir de instalación (default `/usr/local/bin`)       |
| `--ref <git-ref>` | Versión/branch/tag a bajar (default `main`)         |
| `--no-color`      | Desactivar colores                                   |

```bash
# silencioso para automatizar
curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh | bash -s -- -y

# inspeccionar antes de ejecutar (más seguro)
curl -fsSL https://raw.githubusercontent.com/elmaxid/dsh-manage/main/install.sh -o install.sh
less install.sh
bash install.sh
```

> El instalador **no** instala DSH en sí, solo al gestor. Después corrés
> `dsh-manage install` para instalar `@deepseek-ai/dsh`.

### Manual

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
| `DSH_PKG`           | `@deepseek-ai/dsh`                     | Nombre del paquete npm a instalar        |
| `DSH_NPM_CACHE`     | `$DSH_HOME/.npm-cache`                 | Cache de npm para consultas de versión   |

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
