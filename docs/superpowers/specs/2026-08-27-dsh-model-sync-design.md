# Diseño de dsh-model-sync

## Objetivo

Crear un bundle instalable para DeepSeek Harness (DSH) que mantenga sincronizada la lista de modelos configurados con el catálogo anunciado por el endpoint del provider. El plugin añadirá una vista **Modelos** al slot `conversation.view`, junto a Chat, Trajectory y Context.

## Alcance del MVP

- Mostrar todos los providers configurables registrados en DSH.
- Permitir elegir un provider.
- Leer su configuración en el namespace correspondiente; inicialmente se prioriza `llm-pi-ai`.
- Consultar el catálogo mediante `llm.discoverModels`, reutilizando el descubrimiento oficial del adaptador.
- Comparar modelos configurados contra modelos descubiertos.
- Clasificar el resultado como:
  - **Nuevo:** está en el endpoint y no en DSH.
  - **Existente:** está en ambos.
  - **No disponible:** está en DSH y ya no aparece en el endpoint.
- Marcar por defecto los nuevos para agregar y los no disponibles para eliminar.
- Permitir cambiar cada selección mediante checkboxes antes de guardar.
- Persistir la lista final mediante `settings.mutate`, modificando únicamente `providers.<provider>.models`.
- Actualizar la pantalla después de guardar.

No se incluye en el MVP la edición manual avanzada de metadata, la ejecución automática periódica ni la integración dentro de Settings. La arquitectura permitirá añadir estas funciones después.

## Arquitectura elegida

### Bundle DSH instalable

El repositorio será un paquete ESM instalable con:

- `package.json`: declara `dsh.bundle.patch` y el módulo client web.
- `cordis.patch.yml`: inserta una única fila `dsh-model-sync`.
- Host plugin: lógica reutilizable, validación y pruebas de comparación; evita escribir secretos y no accede directamente a archivos de configuración.
- Client plugin: registra la vista `models-sync` en `conversation.view`.

Se usará el slot oficial porque es el mismo mecanismo usado por `dsh-context` para aparecer al lado de Chat. No se reemplazará `conversation`, `conversation.session` ni otro slot de riesgo.

### Acceso a datos

La vista client consumirá la API remota oficial del servicio `connection`:

- `api.llm.providers({})`: providers configurables y sus direcciones de settings.
- `api.settings.describe({})`: valor, user layer y revisión del namespace.
- `api.llm.discoverModels({...})`: catálogo anunciado por el provider.
- `api.settings.mutate({...})`: escritura mínima y concurrentemente segura.

No se implementará un endpoint HTTP propio ni se leerá `settings.yaml` directamente. Esto conserva validación, redacción de secretos, revisión concurrente y eventos de actualización del harness.

## Flujo de datos

1. Al abrir el tab, el client carga providers y descriptores de settings.
2. Selecciona el provider activo o el primero configurable.
3. Extrae `baseURL`, `api` y modelos actuales desde la dirección `settingsNs + settingsPath` del provider.
4. El usuario pulsa **Buscar modelos**.
5. El client llama a `llm.discoverModels` con el provider y su draft de conexión.
6. Una función pura compara ambos catálogos por `id`.
7. La UI presenta el diff y crea la selección inicial:
   - nuevos: agregar;
   - existentes: conservar;
   - no disponibles: eliminar.
8. El usuario modifica checkboxes si lo necesita.
9. Al pulsar **Aplicar sincronización**, se construye la lista final preservando metadata configurada de modelos existentes y adoptando metadata anunciada para modelos nuevos.
10. Se ejecuta un solo `settings.mutate` sobre `providers.<provider>.models` con `expectedRevision`.
11. Se vuelve a cargar la configuración y se muestra el resultado.

## Política de sincronización

La fuente de verdad de disponibilidad será el catálogo devuelto por el endpoint.

- Los modelos nuevos se seleccionan para adopción por defecto.
- Los modelos ausentes se seleccionan para eliminación por defecto.
- Los modelos existentes conservan su configuración local, incluyendo `contextWindow`, `maxTokens`, `compat`, `input` y demás metadata definida por el usuario.
- Para modelos nuevos se adoptan `id`, `name`, `contextWindow` y `maxTokens` cuando el endpoint los proporcione.
- No se modifican otros campos del provider.
- El orden final seguirá primero el orden anunciado por el endpoint; los modelos ausentes que el usuario decida conservar quedan al final en su orden local.

## Protección del modelo predeterminado

Antes de aplicar, el plugin consultará la selección predeterminada expuesta por la superficie disponible del harness.

Si la lista final elimina el modelo predeterminado del mismo provider:

- la operación queda bloqueada;
- la UI explica qué modelo impide la sincronización;
- el usuario debe conservarlo o cambiar primero el modelo predeterminado.

Si la API client actual no expone esa selección, el primer release aplicará una protección conservadora: no permitirá eliminar ningún modelo que figure como selección activa en el catálogo/session disponible. La ausencia de una fuente confiable nunca se interpretará como permiso para eliminar silenciosamente.

## Estados de UI

- Cargando providers/configuración.
- Provider seleccionado sin discovery.
- Consultando endpoint.
- Catálogo vacío.
- Error de autenticación, red o respuesta inválida.
- Diff listo con filtros y contadores.
- Aplicando cambios.
- Conflicto de revisión: recargar y volver a confirmar.
- Sin cambios.
- Sincronización completada.

La vista utilizará variables CSS del tema de DSH, controles accesibles y texto claro. No incorporará un framework visual externo.

## Manejo de errores

- Los errores de `discoverModels` se muestran sin alterar settings.
- Una respuesta sin modelos se trata como advertencia, no como orden automática de borrar todo.
- La eliminación total requiere una confirmación reforzada y no se seleccionará automáticamente cuando el catálogo descubierto esté vacío.
- Un conflicto `expectedRevision` cancela el guardado y recarga el estado.
- Si falla `settings.mutate`, la UI conserva el diff y la selección para poder reintentar.
- IDs vacíos o duplicados se descartan/normalizan antes de comparar; nunca se persisten duplicados.

## Pruebas

### Unitarias

- Clasificación de nuevos, existentes y no disponibles.
- Dedupe por `id` conservando orden estable.
- Preservación de metadata local para existentes.
- Adopción de metadata descubierta para nuevos.
- Conservación opcional de modelos ausentes.
- Catálogo vacío no produce eliminación automática.
- Protección del modelo predeterminado.
- Construcción correcta del path de `settings.mutate`.

### Integración del client

- Registro aditivo del slot `conversation.view` con id propio.
- Carga de providers y settings.
- Discovery, selección y escritura con revisión.
- Estados de error y conflicto.

### Empaquetado y smoke

- Build y tests del paquete.
- Verificación del manifiesto `dsh.bundle`.
- Escaneo de seguridad antes de instalación.
- Instalación aislada mediante `test_drive`.
- Instalación en el profile web solo después de pasar el smoke y con aprobación del usuario.

## Estructura prevista

```text
dsh-model-sync/
├── package.json
├── cordis.patch.yml
├── tsconfig.json
├── tsdown.config.mjs
├── src/
│   ├── index.ts
│   ├── sync.ts
│   └── client/
│       ├── index.tsx
│       ├── ModelSyncView.tsx
│       └── styles.css
├── tests/
│   └── sync.test.ts
└── README.md
```

## Evolución posterior

- Mover o duplicar la superficie dentro de `settings.section`.
- Sincronización periódica opcional y avisos de cambios.
- Políticas por provider: autoagregar, autoeliminar o solo notificar.
- Historial del último catálogo y fecha de sincronización.
- Soporte explícito para otros namespaces/adaptadores de modelos.
