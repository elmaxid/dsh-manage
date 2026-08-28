# dsh-model-sync

Sincroniza la lista de modelos configurados en DeepSeek Harness (DSH) con el
catálogo que anuncia el endpoint del provider, desde una pestaña **Modelos**
junto a Chat, Trajectory y Context.

## Propósito

El plugin añade una vista **Modelos** al slot `conversation.view`. Desde ella
puedes elegir un provider configurable, consultar su catálogo actual mediante
el descubrimiento oficial del adaptador (`llm.discoverModels`) y compararlo con
los modelos que tienes configurados en DSH. El resultado se presenta como un
diff con casillas de verificación:

- **Nuevo:** está en el endpoint y no en DSH. Se marca para agregar por defecto.
- **Existente:** está en ambos. Se conserva tal cual, sin tocar su metadata local.
- **No disponible:** está en DSH y ya no aparece en el endpoint. Se marca para
  eliminar por defecto.

Puedes cambiar cada selección antes de guardar. Al pulsar **Aplicar
sincronización**, el plugin construye la lista final y la persiste con una sola
operación `settings.mutate` sobre `providers.<provider>.models`. No se
modifican otros campos del provider ni se lee `settings.yaml` directamente.

## Semántica de seguridad

El plugin está diseñado para no borrar nada por accidente:

- **Vista previa con diff antes de aplicar.** Nada se escribe hasta que
  confirmas la selección. La UI muestra un resumen de lo que hará la
  aplicación (qué se agrega y qué se elimina) antes de guardar.
- **Un descubrimiento vacío nunca borra nada.** Una respuesta sin modelos se
  trata como advertencia, no como orden de vaciar el catálogo. Además, si la
  selección eliminaría más del 25% del catálogo configurado, se exige una
  confirmación explícita antes de escribir. Dejar un provider sin ningún modelo
  lo vuelve inutilizable, por lo que esa operación se rechaza.
- **Modelos protegidos contra borrado.** Están protegidos el modelo
  predeterminado del host (`host.describe`) y el modelo que la sesión actual
  usará en su próximo paso (`sessions.models`). No son el mismo modelo: este
  despliegue tiene `claude-sonnet-5` como predeterminado mientras la sesión
  activa corre `claude-opus-5`. Si la lista final elimina un modelo protegido
  del mismo provider, la operación queda bloqueada y la UI nombra cada modelo
  que impide la sincronización y por qué está protegido. Si una fuente de
  protección no se puede leer, esa ausencia se trata como *desconocida*, nunca
  como *nada que proteger*: mientras haya una fuente ilegible se rechaza toda
  eliminación, aunque las adiciones siguen permitidas.
- **Escritura con revisión.** La operación `settings.mutate` usa
  `expectedRevision` para no pisar cambios concurrentes. Si otro proceso
  modificó la configuración mientras tanto, el guardado se cancela, se recarga
  el estado y debes volver a confirmar.

## Instalación

```bash
dsh plugin --profile web add ./dsh-model-sync-0.1.0.tgz
```

## Desinstalación

```bash
dsh plugin --profile web remove dsh-model-sync
```

## Desarrollo

```bash
pnpm install --ignore-scripts
pnpm verify
pnpm pack
```

## Soporte en la primera versión

Providers configurables que exponen descubrimiento de modelos,
principalmente los endpoints compatibles con OpenAI `/models` de `llm-pi-ai`.

## Limitaciones

- Sincronización manual únicamente: no hay ejecución automática periódica.
- No incluye un editor avanzado de metadata de modelos.
