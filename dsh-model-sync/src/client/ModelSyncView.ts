import type * as ReactNS from 'react'
import { React, h } from './react.ts'
import type { ModelSyncController } from './controller.ts'
import type { ModelSyncSnapshot } from './types.ts'
import type { DiscoveredModel, ModelProtection } from '../sync.ts'
import { buildFinalModels, hasNoChanges } from '../sync.ts'

export interface ModelSyncViewProps {
  controller: ModelSyncController
}

// Imported rather than duplicated as a literal: comparing against a copy of the
// controller's string meant rewording the message in one file silently dropped
// the "sin cambios" branch here.
import { NO_CHANGES_MESSAGE } from './messages.ts'

const reasonLabel = (reason: ModelProtection['reason']): string =>
  reason === 'host-default' ? 'modelo predeterminado del Host' : 'modelo de la sesión actual'

const discoveredMeta = (model: DiscoveredModel): string => {
  const parts: string[] = []
  if (model.name !== undefined && model.name !== model.id) parts.push(model.name)
  if (model.contextWindow !== undefined) parts.push(`${model.contextWindow} de contexto`)
  if (model.maxTokens !== undefined) parts.push(`${model.maxTokens} máx.`)
  return parts.join(' · ')
}

const providerLabel = (provider: ModelSyncSnapshot['providers'][number]): string => {
  const name = provider.displayName.length > 0 ? provider.displayName : provider.provider
  return provider.active ? `${name} · activo` : name
}

export function ModelSyncView(props: ModelSyncViewProps): ReactNS.ReactElement {
  const { controller } = props
  const state = React.useSyncExternalStore(controller.subscribe, controller.snapshot, controller.snapshot)

  React.useEffect(() => {
    // Controllers outlive the mounted view (they are kept per session), and
    // `load()` resets diff and selection. Reloading unconditionally on every
    // mount discarded a curated set of checkboxes whenever the user switched
    // tabs and came back — and twice over under StrictMode.
    if (controller.snapshot().phase === 'loading') void controller.load()
  }, [controller])

  const busy = state.phase === 'loading' || state.phase === 'discovering' || state.phase === 'applying'
  const selectId = React.useId()
  const diff = state.diff

  /** Protected entries that apply to the currently selected provider, by model id. */
  const protectedHere = new Map(
    state.protection.known
      .filter(entry => entry.provider === state.selectedProvider)
      .map(entry => [entry.model, entry] as const),
  )

  // Live selection numbers, not raw diff counts.
  const willAdd = diff === undefined ? 0 : diff.newModels.filter(model => state.selection.add.has(model.id)).length
  const willRemove = diff === undefined ? 0 : diff.missing.filter(model => state.selection.remove.has(model.id)).length
  const willKeep = diff === undefined
    ? 0
    : diff.existing.length + diff.missing.length - willRemove
  const noChanges = diff !== undefined && hasNoChanges(state.configured, buildFinalModels(diff, state.selection))
  const allAdds = diff !== undefined && diff.newModels.length > 0
    && diff.newModels.every(model => state.selection.add.has(model.id))
  const allRemovals = diff !== undefined && diff.missing.length > 0
    && diff.missing.every(model => state.selection.remove.has(model.id))
  const overBulkThreshold = diff !== undefined && state.removalShare > 0.25

  let message: ReactNS.ReactElement | null = null
  if (state.phase === 'error') {
    message = h('div', { role: 'alert', className: 'dms-message dms-message-error' },
      h('p', { className: 'dms-message-text' }, state.message ?? 'Error inesperado.'),
      h('button', {
        type: 'button',
        className: 'dms-button dms-button-sm',
        disabled: busy,
        onClick: () => { void controller.load() },
      }, 'Recargar configuración'),
    )
  } else if (state.phase === 'success' && state.message !== undefined) {
    const unchanged = state.message === NO_CHANGES_MESSAGE
    message = h('div', {
      role: 'status',
      className: unchanged ? 'dms-message dms-message-unchanged' : 'dms-message dms-message-ok',
    },
      h('p', { className: 'dms-message-text' },
        unchanged ? 'Sin cambios: el catálogo ya coincide con la selección actual.' : state.message),
    )
  } else if (state.phase === 'loading') {
    message = h('div', { role: 'status', className: 'dms-message dms-muted' },
      h('p', { className: 'dms-message-text' }, 'Cargando configuración de modelos…'))
  } else if (state.phase === 'discovering') {
    message = h('div', { role: 'status', className: 'dms-message dms-muted' },
      h('p', { className: 'dms-message-text' }, 'Buscando modelos en el proveedor…'))
  } else if (state.phase === 'applying') {
    message = h('div', { role: 'status', className: 'dms-message dms-muted' },
      h('p', { className: 'dms-message-text' }, 'Aplicando cambios…'))
  }

  let hint: ReactNS.ReactElement | null = null
  if (diff === undefined && state.phase === 'ready') {
    hint = state.providers.length === 0
      ? h('div', { role: 'status', className: 'dms-message dms-muted' },
          h('p', { className: 'dms-message-text' }, 'No hay proveedores con un perfil de modelos en la configuración.'))
      : h('div', { role: 'status', className: 'dms-message dms-muted' },
          h('p', { className: 'dms-message-text' },
            'Pulsa «Buscar modelos» para comparar tu catálogo configurado con el catálogo del proveedor.'))
  }

  return h('div', { className: 'dms-root' },
    h('div', { className: 'dms-card' },
      h('h2', { className: 'dms-title' }, 'Sincronización de modelos'),
      h('p', { className: 'dms-lead dms-muted' },
        'La fuente de verdad es el catálogo publicado por el proveedor: elige qué modelos agregar o eliminar y el resultado se escribirá en la configuración en una sola operación protegida.'),
      message,
      h('section', { className: 'dms-controls' },
        h('label', { className: 'dms-label', htmlFor: selectId }, 'Proveedor'),
        h('select', {
          id: selectId,
          className: 'dms-select',
          value: state.selectedProvider ?? '',
          disabled: busy || state.providers.length === 0,
          onChange: (event: ReactNS.ChangeEvent<HTMLSelectElement>) => {
            controller.selectProvider(event.currentTarget.value)
          },
        },
          state.providers.length === 0
            ? h('option', { value: '' }, 'Sin proveedores')
            : state.providers.map(provider => h('option', {
                key: provider.provider,
                value: provider.provider,
              }, providerLabel(provider))),
        ),
        h('button', {
          type: 'button',
          className: 'dms-button',
          disabled: busy || state.selectedProvider === undefined || state.providers.length === 0,
          onClick: () => { void controller.discover() },
        }, 'Buscar modelos'),
      ),
      hint,
      diff === undefined ? null : h('div', { className: 'dms-diff' },
        overBulkThreshold && !state.bulkAcknowledged
          ? h('div', { role: 'alert', className: 'dms-bulk' },
              h('p', { className: 'dms-bulk-text dms-danger' },
                `Eliminación masiva: se eliminarán ${willRemove} de ${state.configured.length} modelos configurados (más del 25 % del catálogo).`),
              h('button', {
                type: 'button',
                className: 'dms-button dms-button-danger',
                disabled: busy,
                onClick: () => { controller.acknowledgeBulk() },
              }, 'Confirmar eliminación masiva'),
            )
          : null,
        overBulkThreshold && state.bulkAcknowledged
          ? h('div', { role: 'status', className: 'dms-bulk dms-bulk-acked' },
              h('p', { className: 'dms-bulk-text' },
                'Eliminación masiva confirmada para la selección actual. Al cambiar cualquier casilla la confirmación se anulará y tendrás que confirmarla de nuevo.'),
            )
          : null,
        h('p', { role: 'status', className: 'dms-summary' },
          `Se agregarán ${willAdd}, se conservarán ${willKeep}, se eliminarán ${willRemove}.`),
        noChanges
          ? h('p', { role: 'status', className: 'dms-unchanged' },
              'Sin cambios: la selección actual deja el catálogo tal como está.')
          : null,
        state.protection.known.length > 0
          ? h('div', { className: 'dms-protect' },
              h('p', { className: 'dms-protect-title' }, 'Modelos protegidos, no se pueden eliminar:'),
              h('ul', { className: 'dms-protect-list' },
                state.protection.known.map(entry => h('li', {
                  key: `${entry.provider}:${entry.model}:${entry.reason}`,
                }, `${entry.model} — ${reasonLabel(entry.reason)}${
                  entry.provider === state.selectedProvider ? '' : ` (proveedor ${entry.provider})`
                }`)),
              ),
            )
          : null,
        state.protection.unknown.length > 0
          ? h('div', { role: 'alert', className: 'dms-protect dms-protect-unknown' },
              h('p', { className: 'dms-protect-title' },
                'No se pudo verificar toda la protección de modelos: mientras una fuente no sea legible, no se eliminará ningún modelo.'),
              h('ul', { className: 'dms-protect-list' },
                state.protection.unknown.map(entry => h('li', { key: entry.reason },
                  `${reasonLabel(entry.reason)}: ${entry.detail}`)),
              ),
            )
          : null,
        h('section', { className: 'dms-group' },
          h('div', { className: 'dms-group-head' },
            h('h3', { className: 'dms-group-title' }, `Modelos nuevos (${diff.newModels.length})`),
            diff.newModels.length > 0
              ? h('button', {
                  type: 'button',
                  className: 'dms-button dms-button-sm',
                  disabled: busy,
                  onClick: () => { controller.toggleAllAdds() },
                }, allAdds ? 'No seleccionar ninguno' : 'Seleccionar todos')
              : null,
          ),
          diff.newModels.length === 0
            ? h('p', { className: 'dms-muted' }, 'El proveedor no publicó modelos nuevos.')
            : diff.newModels.map(model => h('div', { key: model.id, className: 'dms-row' },
                h('label', { className: 'dms-check' },
                  h('input', {
                    type: 'checkbox',
                    checked: state.selection.add.has(model.id),
                    disabled: busy,
                    onChange: () => { controller.toggleAdd(model.id) },
                  }),
                  h('span', { className: 'dms-word dms-word-add' }, 'Agregar'),
                  h('span', { className: 'dms-model-id' }, model.id),
                ),
                h('span', { className: 'dms-muted dms-meta' }, discoveredMeta(model)),
              )),
        ),
        h('section', { className: 'dms-group' },
          h('div', { className: 'dms-group-head' },
            h('h3', { className: 'dms-group-title' }, `Ya configurados (${diff.existing.length})`),
          ),
          diff.existing.length === 0
            ? h('p', { className: 'dms-muted' }, 'Ningún modelo configurado aparece en el catálogo del proveedor.')
            : diff.existing.map(pair => h('div', { key: pair.configured.id, className: 'dms-row dms-row-readonly' },
                h('span', { className: 'dms-model-id' }, pair.configured.id),
                h('span', { className: 'dms-word dms-word-keep' }, 'Conservar'),
              )),
        ),
        h('section', { className: 'dms-group' },
          h('div', { className: 'dms-group-head' },
            h('h3', { className: 'dms-group-title' }, `Ausentes en el proveedor (${diff.missing.length})`),
            diff.missing.length > 0
              ? h('button', {
                  type: 'button',
                  className: 'dms-button dms-button-sm',
                  disabled: busy,
                  onClick: () => { controller.toggleAllRemovals() },
                }, allRemovals ? 'No seleccionar ninguno' : 'Seleccionar todos')
              : null,
          ),
          diff.missing.length === 0
            ? h('p', { className: 'dms-muted' }, 'No falta ningún modelo configurado en el catálogo del proveedor.')
            : diff.missing.map(model => {
                const protection = protectedHere.get(model.id)
                const selectedForRemoval = state.selection.remove.has(model.id)
                return h('div', {
                  key: model.id,
                  className: protection === undefined ? 'dms-row' : 'dms-row dms-row-protected',
                },
                  h('label', { className: 'dms-check' },
                    h('input', {
                      type: 'checkbox',
                      checked: selectedForRemoval,
                      // A protected model is never removable, so its box is
                      // always disabled. Gating on `!selectedForRemoval` made
                      // it a one-way latch: it rendered checked and enabled,
                      // claiming the model would be deleted while also saying
                      // it was protected, and once unchecked it could not be
                      // checked again.
                      disabled: busy || protection !== undefined,
                      onChange: () => { controller.toggleRemove(model.id) },
                    }),
                    h('span', { className: 'dms-word dms-word-remove' }, 'Eliminar'),
                    h('span', { className: 'dms-model-id' }, model.id),
                  ),
                  protection === undefined
                    ? null
                    : h('span', { className: 'dms-tag-protected' },
                        `Protegido: ${reasonLabel(protection.reason)}`),
                )
              }),
        ),
        h('div', { className: 'dms-actions' },
          state.writable
            ? null
            : h('span', { role: 'status', className: 'dms-muted' },
                'La configuración no es modificable desde esta vista.'),
          h('button', {
            type: 'button',
            className: 'dms-button dms-button-primary',
            disabled: busy || !state.writable,
            onClick: () => { void controller.apply() },
          }, state.phase === 'applying' ? 'Aplicando…' : 'Aplicar sincronización'),
        ),
      ),
    ),
  )
}

export default ModelSyncView
