# dsh-model-sync — Informe de implementación, revisión y verificación

**Fecha:** 2026-08-28
**Estado:** implementado, revisado multi-modelo, verificado end-to-end e instalado en el perfil `web` (31.º plugin).
**Artefacto:** `dsh-model-sync/dsh-model-sync-0.1.0.tgz`
**Spec:** [`2026-08-27-dsh-model-sync-design.md`](./specs/2026-08-27-dsh-model-sync-design.md) · **Plan:** [`../plans/2026-08-27-dsh-model-sync.md`](../plans/2026-08-27-dsh-model-sync.md)

## Resumen ejecutivo

Plugin bundle de DSH que agrega un tab **"Modelos"** al lado de Chat. Sincroniza el
catálogo configurado en settings contra lo que sirve realmente el endpoint del
provider, con preview de diff, checkboxes, protección del modelo por defecto del
host y de la sesión activa, y escritura única con `expectedRevision`.

Verificado en producción contra `ollama-mke` (`http://10.50.1.67:4000/v1`):

| Acción | Modelos |
|---|---|
| Agregar (2) | `glm-5.3-flash-ollama`, `glm-5.3` |
| Conservar (40) | resto del catálogo |
| Eliminar (1) | `glm-5.3-flash-zai` |

Es decir: el plugin detectó por sí solo los modelos 5.3 recién publicados — el
caso de uso que lo motivó.

## Qué se construyó

```
dsh-model-sync/
├── package.json            # dsh.bundle + dsh.client (web), exports ./ y ./client
├── cordis.patch.yml        # fila host dsh-model-sync
├── tsconfig.json           # host: node22, allowImportingTsExtensions, noEmit
├── tsconfig.client.json    # cliente: types [] (sin @types/node), strict
├── tsdown.config.mjs       # dual-entry: host ESM .js + cliente CJS con wrapper
├── src/index.ts            # mitad host deliberadamente inerte
├── src/sync.ts             # motor puro: normalización, diff, selección, guard
├── src/client/
│   ├── types.ts            # contratos del snapshot y del wire
│   ├── controller.ts       # ModelSyncController: estado + escrituras seguras
│   ├── messages.ts         # mensajes compartidos controller↔vista
│   ├── register.ts         # seam de registro en el slot conversation.view
│   ├── react.ts            # puente require('react') inyectado
│   ├── ModelSyncView.ts    # vista (React.createElement, sin JSX)
│   ├── index.ts            # plugin cliente { name, inject:['slots'], apply }
│   ├── styles.css          # hoja .dms-* con tokens de tema del host
│   └── globals.d.ts        # ambientes del bundle CJS
└── tests/                  # 37 tests: sync, controller, register, manifest
```

Semántica de seguridad (detalle completo en el README del paquete): preview
obligatoria, descubrimiento vacío nunca borra, lista final vacía se rechaza,
protección tri-valuada (una fuente ilegible **bloquea eliminaciones** pero
permite adiciones), umbral de eliminación masiva del 25 % con confirmación
invalidable, un solo `settings.mutate` con `expectedRevision` que solo toca
`providers.<provider>.models`.

## Proceso de ejecución

Spec → plan (~1357 líneas, corregido por revisión multi-modelo antes de
implementar) → routing por tarea → implementación → revisión fan-out →
arbitraje → fixes → verificación → empaquetado → instalación.

### Routing de tareas (modelo por especialidad)

| Tarea | Modelo | Criterio |
|---|---|---|
| 1. Scaffold + normalización | `glm-5.3-flash` | mecánica, verificable por tests |
| 2. Diff + guard de protección | `codex-gpt56-sol` | falla silenciosa |
| 3. Wire controller | `codex-gpt56-terra` | falla silenciosa |
| 4a. Registro del slot | `glm-5.3-flash` | contrato chico |
| 4b. Vista React + CSS | `glm-5.3-zai` | error visible |
| 5. Manifest + docs | `deepseek-v4-flash` | independiente, texto |
| 6. Scan + pack + smoke | orquestador | gate de aprobación del usuario |

Criterio aplicado: gastar velocidad donde el error es detectable por tests o por
la UI, y capacidad donde el error es **silencioso** (guard de protección,
estabilidad referencial del snapshot). En paralelo solo corrieron los pares con
archivos disjuntos (1∥5 y 4a∥4b); el resto era cadena estricta por dependencia
de interfaces y por archivo compartido.

### Revisión multi-modelo

4 revisores en paralelo con focos disjuntos (seguridad, cliente React,
fidelidad al plan/tests, integración runtime/concurrencia), ninguno revisando
su propio código. Produjeron 19 hallazgos con severidades infladas.

Árbitro (`claude-opus-5`, sin haber escrito nada): verificó cada hallazgo
contra el código real, con reproducción ejecutable donde fue posible. Veredicto:
**30 confirmados** (2 con cita imprecisa), **3 refutados** (C-H8 el Map
por sesión es fiel al plan; C-H9 el defecto real era B3; D3 `dsh.client.inject`
es metadata informativa, el plugin de referencia hace lo mismo), y varias
severidades recalibradas en ambos sentidos.

Los dos hallazgos que justificaron todo el proceso:

1. **C-H7/D1 (crítico): el paquete no cargaba.** `"type": "module"` hace que
   tsdown emita `.mjs`/`.d.mts`, pero el manifiesto prometía
   `lib/index.js`/`lib/index.d.ts`. El entry host resolvía a un archivo
   inexistente (`ERR_MODULE_NOT_FOUND` reproducido). Ni la suite ni el typecheck
   lo detectaban. Fix: `outExtensions: () => ({ js: '.js', dts: '.d.ts' })` en
   tsdown, más un test de manifiesto que verifica `existsSync` sobre cada entry
   declarado (C-H12/D2 — la red que debió atraparlo).
2. **D4 (crítico): escritura cruzada de provider.** `discover()` capturaba el
   draft antes del `await` y publicaba el diff sin verificar el proveedor;
   cambiar de provider durante un descubrimiento en vuelo escribía el catálogo
   de uno sobre el de otro, **con la UI reportando éxito**. El árbitro agravó el
   hallazgo: construyó el caso de diff cruzado *aditivo*, donde ni el guard de
   eliminación masiva ni el de protección se disparan. Fix: el diff se sella con
   `diffProvider` y `apply()` lo reverifica; además `discover()`/`apply()` son
   ya no reentrantes y los resultados obsoletos se descartan.

Otros confirmados y corregidos: `settings.mutate` sin try/catch congelaba el tab
en `applying` ante un fallo de transporte (C-H11); `success` incondicional
pisaba el error de la recarga post-escritura (A1/D6, reproducido con
`providers: []` bajo banner verde); protegidos preseleccionados para eliminar
con pestillo unidireccional (B3, reproducido con la config real); respuesta
malformada del wire lanzaba `TypeError` fuera del try (A3); Map de controllers
sin purga, disposer descartado, carga en remontaje que borraba la selección
curada, mensaje "sin cambios" acoplado por literal, import muerto, alias
muerto, superficie exportada excesiva.

Verificación de las regresiones por **mutación**: neutralizar cada guard hace
fallar exactamente el test que lo cubre. El árbitro había demostrado antes que
5 tests preexistentes seguían verdes con el código roto — la mutación es lo que
separa un test real de uno decorativo.

## Verificación

- **37/37 tests**, `tsc --noEmit` host y cliente en 0, `pnpm verify` completo.
- **Gate de seguridad:** `plugin_vet` FAIL 89/100 por falsos positivos (URL de
  la licencia Apache y mock `example.test` leídos como "endpoints salientes",
  bundle minificado leído como "ofuscado", ausencia de CI). Único punto
  accionable corregido: campo `repository`. Sin dependencias de runtime, sin
  patrones peligrosos, sin scripts de instalación. Decisión consciente de
  avanzar sobre un FAIL explicado, informada al usuario.
- **Smoke aislado** en un `DSH_HOME` desechable: install, fila en la
  composición, entry host importable, wrapper del bundle cliente correcto.
- **Instalación real:** perfil `web` de 30 → 31 plugins, ningún plugin perdido
  (verificado por comparación de manifiestos; backup en
  `/tmp/web-package.json.bak`). Reinicio vía `systemctl restart dsh`.
- **E2E en navegador headless** (Chromium de Playwright ya presente en el
  sistema, vía `--executable-path`): tab renderiza al lado de Chat, selector
  "ollama-mke · activo", descubrimiento real contra el endpoint con el diff
  de la tabla superior, sección de protegidos visible, sin errores de consola.

## Estado y operación

- Instalado y funcionando. Para usarlo: refrescar el GUI, abrir una
  conversación, tab **Modelos** → **Buscar modelos** → ajustar checkboxes →
  **Aplicar sincronización**.
- Desinstalar: `dsh plugin --profile web remove dsh-model-sync`.
- Desarrollo: `pnpm install --ignore-scripts && pnpm verify && pnpm pack`.

## Limitaciones conocidas

- Sincronización manual; no hay ejecución periódica.
- Un solo provider a la vez (selector).
- Sin i18n: UI en español, deliberado para este despliegue.
- El tab requiere sesión activa (el slot `conversation.view` es session-scoped);
  sin `sessionId` muestra un mensaje en lugar de degradar.

## Lecciones del proceso

1. **El árbitro con acceso a la realidad es lo que hace útil la revisión.** 7 de
   19 hallazgos venían sobre-calificados y 3 eran falsos positivos; sin
   verificación contra código/config real, se habrían "arreglado" cosas sanas.
2. **Los errores más caros son los silenciosos.** El paquete roto y la escritura
   cruzada pasaban toda la suite. Los tests de regresión sin mutación no
   prueban nada.
3. **`"type": "module"` cambia la extensión que tsdown emite.** El test de
   manifiesto debe afirmar existencia de cada entry declarado, no solo del
   allowlist `files`.
4. **Capturar un draft antes de un `await` y usarlo después** es un patrón de
   carrera; en herramientas de escritura, todo resultado en vuelo debe sellarse
   con su sujeto y reverificarse al consumirse.
5. **Un `ok: false` no cubre el rechazo de transporte.** Todo `await` de RPC
   bajo un handler `void` necesita su propio try/catch.
6. Herramientas del harness con bugs propios durante esta sesión: `gate_scan`
   (esquema), `drive_report` (esquema), `gate_guard` (inutilizable por CLI);
   todas las verificaciones se suplieron a mano. El perfil `web` no acepta smoke
   headless (ni `-p` ni posicional).
