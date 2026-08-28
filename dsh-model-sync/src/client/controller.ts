import {
  blockedRemovals,
  buildFinalModels,
  bulkRemovalShare,
  defaultSelection,
  diffModels,
  hasNoChanges,
  modelsMutation,
} from '../sync.ts'
import type { ModelProfile, ProtectionState, SyncSelection } from '../sync.ts'
import type {
  ModelSyncApi,
  ModelSyncSnapshot,
  NamespaceView,
  ProviderView,
  RpcResult,
} from './types.ts'

interface ProviderDraft {
  provider: ProviderView
  namespace: NamespaceView
  api?: string
  baseURL?: string
  models: ModelProfile[]
}

type Listener = () => void

const emptySelection = (): SyncSelection => ({ add: new Set(), remove: new Set() })
const emptyProtection = (): ProtectionState => ({ known: [], unknown: [] })

function unwrap<T>(reply: RpcResult<T>): T {
  if (!reply.result.ok) throw new Error(reply.result.error.message)
  return reply.result.value
}

function objectAtPath(value: unknown, path: readonly string[]): Record<string, unknown> | undefined {
  let current: unknown = value
  for (const key of path) {
    if (current === null || typeof current !== 'object' || Array.isArray(current)) return undefined
    current = (current as Record<string, unknown>)[key]
  }
  return current !== null && typeof current === 'object' && !Array.isArray(current)
    ? current as Record<string, unknown>
    : undefined
}

function profileFrom(namespace: NamespaceView, provider: ProviderView): Omit<ProviderDraft, 'provider' | 'namespace'> | undefined {
  const profile = objectAtPath(namespace.value, provider.settingsPath)
  if (profile === undefined) return undefined
  const models = Array.isArray(profile.models)
    ? profile.models.filter((model): model is ModelProfile => model !== null && typeof model === 'object' && !Array.isArray(model) && typeof (model as { id?: unknown }).id === 'string').map(model => ({ ...model }))
    : []
  return {
    api: typeof profile.api === 'string' ? profile.api : undefined,
    baseURL: typeof profile.baseURL === 'string' ? profile.baseURL : undefined,
    models,
  }
}

export class ModelSyncController {
  private readonly listeners = new Set<Listener>()
  private drafts = new Map<string, ProviderDraft>()
  private selectedDraft?: ProviderDraft
  private state: ModelSyncSnapshot = {
    phase: 'loading', providers: [], configured: [], selection: emptySelection(), writable: false,
    protection: emptyProtection(), removalShare: 0, bulkAcknowledged: false,
  }

  constructor(private readonly api: ModelSyncApi, private readonly sessionId: string) {}

  readonly snapshot = (): ModelSyncSnapshot => this.state

  readonly subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  private publish(next: ModelSyncSnapshot): void {
    this.state = next
    for (const listener of this.listeners) listener()
  }

  private transition(change: Partial<ModelSyncSnapshot>): void {
    this.publish({ ...this.state, ...change })
  }

  private protectionFrom(
    host: PromiseSettledResult<RpcResult<{ provider?: string; model?: string }>>,
    session: PromiseSettledResult<RpcResult<{ current?: { provider?: string; model?: string } }>>,
  ): ProtectionState {
    const protection = emptyProtection()
    if (host.status === 'fulfilled' && host.value.result.ok && host.value.result.value.provider && host.value.result.value.model) {
      protection.known.push({ provider: host.value.result.value.provider, model: host.value.result.value.model, reason: 'host-default' })
    } else {
      protection.unknown.push({ reason: 'host-default', detail: 'No se pudo leer el modelo predeterminado del Host.' })
    }
    const current = session.status === 'fulfilled' && session.value.result.ok ? session.value.result.value.current : undefined
    if (current?.provider && current.model) {
      protection.known.push({ provider: current.provider, model: current.model, reason: 'active-session' })
    } else {
      protection.unknown.push({ reason: 'active-session', detail: 'No se pudo leer el modelo de la sesión actual.' })
    }
    return protection
  }

  private selectDraft(id: string | undefined): void {
    this.selectedDraft = id === undefined ? undefined : this.drafts.get(id)
  }

  async load(): Promise<void> {
    this.transition({ phase: 'loading', message: undefined })
    const [providersResult, settingsResult, hostResult, sessionResult] = await Promise.allSettled([
      this.api.llm.providers({}), this.api.settings.describe({}), this.api.host.describe({}), this.api.sessions.models({ sessionId: this.sessionId }),
    ])
    if (providersResult.status !== 'fulfilled' || settingsResult.status !== 'fulfilled' || !providersResult.value.result.ok || !settingsResult.value.result.ok) {
      this.drafts = new Map()
      this.selectDraft(undefined)
      this.transition({ phase: 'error', providers: [], selectedProvider: undefined, configured: [], diff: undefined, diffProvider: undefined, selection: emptySelection(), writable: false, protection: this.protectionFrom(hostResult, sessionResult), removalShare: 0, bulkAcknowledged: false, message: 'No se pudo cargar la configuración de modelos.' })
      return
    }

    const { providers } = unwrap(providersResult.value)
    const settings = unwrap(settingsResult.value)
    const namespaces = new Map(settings.namespaces.map(namespace => [namespace.ns, namespace]))
    const drafts = new Map<string, ProviderDraft>()
    for (const provider of providers) {
      const namespace = namespaces.get(provider.settingsNs)
      if (namespace === undefined || provider.settingsPath.length === 0) continue
      const profile = profileFrom(namespace, provider)
      if (profile === undefined) continue
      drafts.set(provider.provider, { provider, namespace, ...profile })
    }
    const prior = this.state.selectedProvider
    this.drafts = drafts
    const selected = prior !== undefined && drafts.has(prior)
      ? prior
      : [...drafts.values()].find(draft => draft.provider.active)?.provider.provider ?? drafts.keys().next().value
    this.selectDraft(selected)
    const configured = this.selectedDraft?.models ?? []
    this.transition({
      phase: 'ready', providers: [...drafts.values()].map(draft => draft.provider), selectedProvider: selected,
      configured, diff: undefined, diffProvider: undefined, selection: emptySelection(), writable: settings.writable,
      protection: this.protectionFrom(hostResult, sessionResult), removalShare: 0, bulkAcknowledged: false, message: undefined,
    })
  }

  selectProvider(id: string): void {
    if (!this.drafts.has(id) || id === this.state.selectedProvider) return
    this.selectDraft(id)
    this.transition({ phase: 'ready', selectedProvider: id, configured: this.selectedDraft?.models ?? [], diff: undefined, diffProvider: undefined, selection: emptySelection(), removalShare: 0, bulkAcknowledged: false, message: undefined })
  }

  async discover(): Promise<void> {
    const draft = this.selectedDraft
    if (draft === undefined) return
    // A discovery is bound to the provider it was started for. Both guards below
    // exist because `selectProvider` can run while this await is in flight:
    // without them a catalog discovered for provider A is published as the diff
    // for provider B and then written to B's settings path, destroying B's
    // catalog. An additive cross-provider diff passes every later guard.
    if (this.state.phase === 'discovering' || this.state.phase === 'applying') return
    const owner = draft.provider.provider
    this.transition({ phase: 'discovering', message: undefined })
    let discovered
    try {
      discovered = unwrap(await this.api.llm.discoverModels({
        settingsNs: draft.provider.settingsNs, provider: owner, baseURL: draft.baseURL, api: draft.api,
      })).models
    } catch (error) {
      if (this.selectedDraft?.provider.provider !== owner) return
      this.transition({ phase: 'error', diff: undefined, diffProvider: undefined, selection: emptySelection(), removalShare: 0, bulkAcknowledged: false, message: error instanceof Error ? error.message : 'No se pudieron descubrir los modelos.' })
      return
    }
    // The selection moved on while the endpoint was answering: this reply is
    // stale and must not touch the state of whatever provider is selected now.
    if (this.selectedDraft?.provider.provider !== owner) return
    if (!Array.isArray(discovered) || discovered.length === 0) {
      this.transition({ phase: 'error', diff: undefined, diffProvider: undefined, selection: emptySelection(), removalShare: 0, bulkAcknowledged: false, message: 'El endpoint no anunció modelos; no se aplicará ninguna eliminación.' })
      return
    }
    const diff = diffModels(draft.models, discovered)
    const selection = this.withoutProtected(defaultSelection(diff), owner)
    this.transition({ phase: 'diff', diff, diffProvider: owner, selection, removalShare: bulkRemovalShare(diff.configured, buildFinalModels(diff, selection)), bulkAcknowledged: false, message: undefined })
  }

  /**
   * Drops protected models from a removal set. `defaultSelection` is a pure
   * function with no access to protection state, so it preselects every missing
   * model — including the host default and the active session model. Leaving
   * them selected made the UI promise a deletion that `apply` was always going
   * to refuse, and made the bulk-removal share count models that can never go.
   */
  private withoutProtected(selection: SyncSelection, provider: string): SyncSelection {
    const protectedIds = new Set(
      this.state.protection.known
        .filter(entry => entry.provider === provider)
        .map(entry => entry.model.trim()),
    )
    if (protectedIds.size === 0) return selection
    const remove = new Set<string>()
    for (const id of selection.remove) if (!protectedIds.has(id)) remove.add(id)
    return { add: selection.add, remove }
  }

  private withSelection(selection: SyncSelection): void {
    const diff = this.state.diff
    if (diff === undefined) return
    this.transition({ selection, removalShare: bulkRemovalShare(diff.configured, buildFinalModels(diff, selection)), bulkAcknowledged: false, message: undefined })
  }

  toggleAdd(id: string): void {
    const add = new Set(this.state.selection.add)
    add.has(id) ? add.delete(id) : add.add(id)
    this.withSelection({ add, remove: new Set(this.state.selection.remove) })
  }

  toggleRemove(id: string): void {
    const remove = new Set(this.state.selection.remove)
    remove.has(id) ? remove.delete(id) : remove.add(id)
    this.withSelection({ add: new Set(this.state.selection.add), remove })
  }

  toggleAllAdds(): void {
    const diff = this.state.diff
    if (diff === undefined) return
    const ids = diff.newModels.map(model => model.id)
    const add = ids.every(id => this.state.selection.add.has(id)) ? new Set<string>() : new Set(ids)
    this.withSelection({ add, remove: new Set(this.state.selection.remove) })
  }

  toggleAllRemovals(): void {
    const diff = this.state.diff
    if (diff === undefined) return
    const ids = diff.missing.map(model => model.id)
    const all = this.withoutProtected({ add: this.state.selection.add, remove: new Set(ids) }, this.state.diffProvider ?? '')
    const remove = [...all.remove].every(id => this.state.selection.remove.has(id)) && this.state.selection.remove.size === all.remove.size
      ? new Set<string>()
      : all.remove
    this.withSelection({ add: new Set(this.state.selection.add), remove })
  }

  acknowledgeBulk(): void {
    this.transition({ bulkAcknowledged: true })
  }

  async apply(): Promise<void> {
    const draft = this.selectedDraft
    const diff = this.state.diff
    if (draft === undefined || diff === undefined || !this.state.writable) return
    if (this.state.phase === 'applying' || this.state.phase === 'discovering') return
    // Last line of defence: never write a catalog discovered for one provider
    // into the settings path of another.
    if (this.state.diffProvider !== draft.provider.provider) {
      this.transition({ phase: 'error', message: 'El diff pertenece a otro proveedor; vuelve a descubrir los modelos.' })
      return
    }
    const finalModels = buildFinalModels(diff, this.state.selection)
    if (finalModels.length === 0) {
      this.transition({ phase: 'error', message: 'Un proveedor sin modelos no es utilizable; conserva al menos uno.' })
      return
    }
    const blocked = blockedRemovals(draft.provider.provider, finalModels, this.state.protection, this.state.configured)
    if (blocked.length > 0) {
      const descriptions = blocked.map(entry => `${entry.model} (${entry.reason === 'host-default' ? 'modelo predeterminado' : entry.reason === 'active-session' ? 'modelo de la sesión actual' : 'protección desconocida'})`)
      this.transition({ phase: 'error', message: `No se pueden eliminar: ${descriptions.join(', ')}. Conserva el modelo o cambia el valor predeterminado/modelo de sesión primero.` })
      return
    }
    if (hasNoChanges(this.state.configured, finalModels)) {
      this.transition({ phase: 'success', message: 'No hay cambios que aplicar.' })
      return
    }
    const share = bulkRemovalShare(this.state.configured, finalModels)
    if (share > 0.25 && !this.state.bulkAcknowledged) {
      const removed = Math.round(share * this.state.configured.length)
      this.transition({ phase: 'error', removalShare: share, message: `Se eliminarán ${removed} de ${this.state.configured.length} modelos; confirma para continuar.` })
      return
    }
    this.transition({ phase: 'applying', message: undefined })
    let reply
    try {
      reply = await this.api.settings.mutate({ ns: draft.provider.settingsNs, ops: [modelsMutation(draft.provider.settingsPath, finalModels)], expectedRevision: draft.namespace.revision })
    } catch (error) {
      // A transport rejection is not an `ok: false` envelope. Without this catch
      // the promise escapes through the view's `void apply()` and the tab stays
      // frozen in `applying` with every control disabled and no message.
      this.transition({ phase: 'error', message: error instanceof Error ? error.message : 'No se pudo escribir la configuración.' })
      return
    }
    if (!reply.result.ok) {
      const conflict = reply.result.error.code === 'settings-conflict' || reply.result.error.message.includes('settings-conflict')
      this.transition({ phase: 'error', message: conflict ? 'La configuración cambió; recarga y descubre los modelos de nuevo.' : reply.result.error.message })
      return
    }
    // The write landed. If the reload fails, say so instead of overwriting its
    // error with a success banner over an empty view.
    await this.load()
    if (this.state.phase === 'error') {
      this.transition({ message: 'Se aplicaron los cambios, pero no se pudo recargar la configuración. Recarga la pestaña.' })
      return
    }
    this.transition({ phase: 'success', message: 'Modelos sincronizados correctamente.' })
  }
}
