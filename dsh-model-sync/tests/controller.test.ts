import { describe, expect, test } from 'vitest'
import { ModelSyncController } from '../src/client/controller.ts'
import type {
  ModelSyncApi,
  NamespaceView,
  ProviderView,
  RpcResult,
} from '../src/client/types.ts'
import type { DiscoveredModel, ModelProfile } from '../src/sync.ts'

type Options = {
  providers?: ProviderView[]
  configured?: ModelProfile[]
  namespaces?: NamespaceView[]
  host?: { provider?: string; model?: string }
  sessionCurrent?: { provider?: string; model?: string }
  discovered?: DiscoveredModel[]
  hostFails?: boolean
  sessionModelsFails?: boolean
  discoverFails?: boolean
  mutateFails?: boolean
  mutateError?: { message: string; code?: string }
}

const ok = <T>(value: T): RpcResult<T> => ({ result: { ok: true, value } })
const fail = <T>(message: string, code?: string): RpcResult<T> => ({ result: { ok: false, error: { message, code } } })

function fakeApi(options: Options = {}) {
  const providers = options.providers ?? [{
    provider: 'route-a', displayName: 'Route A', settingsNs: 'llm-pi-ai',
    settingsPath: ['providers', 'route-a'], active: true,
  }]
  const configured = options.configured ?? [{ id: 'old' }]
  const namespaces = options.namespaces ?? [{
    ns: 'llm-pi-ai', revision: 4, value: {
      providers: { 'route-a': { api: 'openai-completions', baseURL: 'https://example.test/v1', models: configured } },
    },
  }]
  const calls: {
    discover: Array<{ settingsNs: string; provider?: string; baseURL?: string; api?: string }>
    mutate: Array<{ ns: string; ops: Array<{ op: 'set'; path: string[]; value: unknown }>; expectedRevision?: number }>
  } = { discover: [], mutate: [] }
  const api: ModelSyncApi = {
    llm: {
      providers: async () => ok({ providers }),
      discoverModels: async request => {
        calls.discover.push(request)
        return options.discoverFails
          ? fail('discovery failed')
          : ok({ models: options.discovered ?? [] })
      },
    },
    settings: {
      describe: async () => ok({ writable: true, namespaces }),
      mutate: async request => {
        calls.mutate.push(request)
        return options.mutateFails
          ? fail(options.mutateError?.message ?? 'mutation failed', options.mutateError?.code)
          : ok({ ns: request.ns, revision: 5, value: namespaces[0]?.value })
      },
    },
    host: {
      describe: async () => options.hostFails
        ? fail('host unavailable')
        : ok(options.host ?? { provider: 'route-a', model: 'old' }),
    },
    sessions: {
      models: async () => options.sessionModelsFails
        ? fail('session unavailable')
        : ok({ current: options.sessionCurrent ?? { provider: 'route-a', model: 'old' } }),
    },
  }
  return { api, calls }
}


describe('ModelSyncController regressions', () => {
  /**
   * A discovery started for provider A must never be written to provider B.
   * The dangerous shape is an ADDITIVE cross-provider diff: it removes nothing,
   * so the bulk-removal and protection guards never fire, and the write lands
   * silently while the UI reports success.
   */
  test('never writes a catalog discovered for one provider into another', async () => {
    let release: (() => void) | undefined
    const gate = new Promise<void>(resolve => { release = resolve })
    const providers: ProviderView[] = [
      { provider: 'route-a', displayName: 'A', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-a'], active: true },
      { provider: 'route-b', displayName: 'B', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-b'], active: true },
    ]
    const namespaces: NamespaceView[] = [{
      ns: 'llm-pi-ai', revision: 4, value: {
        providers: {
          'route-a': { models: [{ id: 'a1' }] },
          'route-b': { models: [{ id: 'b1' }, { id: 'b2' }, { id: 'b3' }, { id: 'b4' }] },
        },
      },
    }]
    const mutate: Array<{ ops: Array<{ path: string[]; value: unknown }> }> = []
    const api = {
      llm: {
        providers: async () => ok({ providers }),
        // Only route-a's discovery is slow; it resolves after the switch.
        discoverModels: async (request: { provider?: string }) => {
          if (request.provider === 'route-a') await gate
          return ok({ models: [{ id: 'a1' }, { id: 'a2' }] })
        },
      },
      settings: {
        describe: async () => ok({ writable: true, namespaces }),
        mutate: async (request: { ops: Array<{ path: string[]; value: unknown }> }) => {
          mutate.push(request)
          return ok({ ns: 'llm-pi-ai', revision: 5, value: namespaces[0]?.value })
        },
      },
      host: { describe: async () => ok({ provider: 'route-a', model: 'a1' }) },
      sessions: { models: async () => ok({ current: { provider: 'route-a', model: 'a1' } }) },
    } as unknown as ModelSyncApi

    const controller = new ModelSyncController(api, 'session-1')
    await controller.load()
    const inFlight = controller.discover()
    controller.selectProvider('route-b')
    release?.()
    await inFlight

    // The stale reply must not have become route-b's diff.
    expect(controller.snapshot().diffProvider).not.toBe('route-a')
    await controller.apply()
    for (const request of mutate) {
      for (const op of request.ops) {
        expect(op.path).not.toEqual(['providers', 'route-b', 'models'])
      }
    }
  })

  test('surfaces a transport rejection instead of freezing in applying', async () => {
    const { api } = fakeApi({ configured: [{ id: 'old' }], discovered: [{ id: 'old' }, { id: 'new' }] })
    // An `ok: false` envelope is a business failure; a thrown rejection is a
    // transport failure, and only the latter used to escape uncaught.
    api.settings.mutate = async () => { throw new Error('connection lost') }
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover()
    await expect(controller.apply()).resolves.toBeUndefined()
    expect(controller.snapshot().phase).toBe('error')
    expect(controller.snapshot().message).toContain('connection lost')
  })

  test('reports a failed reload instead of claiming success over an empty view', async () => {
    const { api, calls } = fakeApi({ configured: [{ id: 'old' }], discovered: [{ id: 'old' }, { id: 'new' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover()
    // Break the reload only after the write has been accepted.
    api.llm.providers = async () => fail('providers unavailable')
    await controller.apply()
    expect(calls.mutate).toHaveLength(1)
    expect(controller.snapshot().message).not.toContain('correctamente')
    expect(controller.snapshot().message).toContain('no se pudo recargar')
  })

  test('ignores a discovery started while another is already in flight', async () => {
    const { api, calls } = fakeApi({ configured: [{ id: 'old' }], discovered: [{ id: 'old' }, { id: 'new' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load()
    await Promise.all([controller.discover(), controller.discover()])
    expect(calls.discover).toHaveLength(1)
  })
})

describe('ModelSyncController', () => {
  test('loads configurable providers, settings profile, revision, and host default', async () => {
    const api = fakeApi({
      providers: [{ provider: 'route-a', displayName: 'Route A', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-a'], active: true }],
      namespaces: [{ ns: 'llm-pi-ai', revision: 4, value: { providers: { 'route-a': { api: 'openai-completions', baseURL: 'https://example.test/v1', models: [{ id: 'old' }] } } } }],
      host: { provider: 'route-a', model: 'old' },
      sessionCurrent: { provider: 'route-a', model: 'old' },
    }).api
    const controller = new ModelSyncController(api, 'session-1')

    await controller.load()

    expect(controller.snapshot()).toMatchObject({ phase: 'ready', selectedProvider: 'route-a', configured: [{ id: 'old' }] })
    expect(controller.snapshot().protection.known).toContainEqual({ provider: 'route-a', model: 'old', reason: 'host-default' })
    expect(controller.snapshot().protection.unknown).toEqual([])
  })

  test('filters providers with an empty settings path', async () => {
    const { api } = fakeApi({
      providers: [
        { provider: 'unsafe', displayName: 'Unsafe', settingsNs: 'llm-pi-ai', settingsPath: [], active: true },
        { provider: 'route-a', displayName: 'Route A', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-a'], active: false },
      ],
    })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load()
    expect(controller.snapshot().providers.map(provider => provider.provider)).toEqual(['route-a'])
  })

  test('discovers with the provider settings address and creates default selections', async () => {
    const { api, calls } = fakeApi({ discovered: [{ id: 'new' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load()
    await controller.discover()

    expect(calls.discover[0]).toEqual({ settingsNs: 'llm-pi-ai', provider: 'route-a', baseURL: 'https://example.test/v1', api: 'openai-completions' })
    expect(controller.snapshot().selection.add).toEqual(new Set(['new']))
  })

  test('returns a referentially stable snapshot between transitions', async () => {
    const controller = new ModelSyncController(fakeApi({}).api, 'session-1')
    await controller.load()
    expect(controller.snapshot()).toBe(controller.snapshot())
    const before = controller.snapshot()
    await controller.discover()
    expect(controller.snapshot()).not.toBe(before)
  })

  test('exposes snapshot and subscribe as detachable references', async () => {
    const controller = new ModelSyncController(fakeApi({}).api, 'session-1')
    const { snapshot, subscribe } = controller
    expect(() => snapshot()).not.toThrow()
    const unsubscribe = subscribe(() => {})
    await controller.load()
    expect(snapshot().phase).toBe('ready')
    unsubscribe()
  })

  test('discards a diff belonging to another provider when the selection changes', async () => {
    const { api } = fakeApi({
      providers: [
        { provider: 'route-a', displayName: 'A', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-a'], active: true },
        { provider: 'route-b', displayName: 'B', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-b'], active: true },
      ],
      namespaces: [{ ns: 'llm-pi-ai', revision: 4, value: { providers: {
        'route-a': { api: 'openai-completions', baseURL: 'https://example.test/v1', models: [{ id: 'old' }] },
        'route-b': { api: 'openai-completions', models: [{ id: 'other' }] },
      } } }],
      discovered: [{ id: 'from-a' }],
    })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load()
    await controller.discover()
    expect(controller.snapshot().diff).toBeDefined()
    controller.selectProvider('route-b')
    expect(controller.snapshot().diff).toBeUndefined()
    expect(controller.snapshot().selection).toEqual({ add: new Set(), remove: new Set() })
  })

  test('keeps selections immutable, isolated by group, and invalidates acknowledgement', async () => {
    const controller = new ModelSyncController(fakeApi({
      configured: [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }], discovered: [{ id: 'a' }, { id: 'new' }],
    }).api, 'session-1')
    await controller.load()
    await controller.discover()
    const published = controller.snapshot()
    controller.toggleAdd('new')
    expect(published.selection.add).toEqual(new Set(['new']))
    expect(controller.snapshot().selection.add).toEqual(new Set())
    controller.acknowledgeBulk()
    controller.toggleAllRemovals()
    expect(controller.snapshot().selection.remove.size).toBe(0)
    expect(controller.snapshot().selection.add).toEqual(new Set())
    expect(controller.snapshot().bulkAcknowledged).toBe(false)
    expect(controller.snapshot().removalShare).toBe(0)
    controller.toggleAllRemovals()
    expect(controller.snapshot().selection.remove.size).toBe(3)
  })

  test('reports an empty discovery without auto-removing models', async () => {
    const controller = new ModelSyncController(fakeApi({ discovered: [] }).api, 'session-1')
    await controller.load()
    await controller.discover()
    expect(controller.snapshot()).toMatchObject({ phase: 'error', diff: undefined })
    expect(controller.snapshot().message).toBe('El endpoint no anunció modelos; no se aplicará ninguna eliminación.')
  })

  test('writes exactly one revision-guarded models mutation and reloads after success', async () => {
    const { api, calls } = fakeApi({ discovered: [{ id: 'old' }, { id: 'new' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load()
    await controller.discover()
    await controller.apply()
    expect(calls.mutate).toEqual([{ ns: 'llm-pi-ai', ops: [{ op: 'set', path: ['providers', 'route-a', 'models'], value: [{ id: 'old' }, { id: 'new' }] }], expectedRevision: 4 }])
    expect(controller.snapshot().phase).toBe('success')
  })

  test('blocks applying a catalog that removes the host default model', async () => {
    const { api, calls } = fakeApi({ configured: [{ id: 'old' }, { id: 'gone' }], host: { provider: 'route-a', model: 'gone' }, sessionCurrent: { provider: 'route-a', model: 'old' }, discovered: [{ id: 'old' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover()
    // The host default is never preselected for removal: the UI must not offer
    // a deletion that `apply` is guaranteed to refuse.
    expect(controller.snapshot().selection.remove.has('gone')).toBe(false)
    await controller.apply()
    // It is still absent remotely, so it stays in the catalog and the write is
    // a genuine no-op rather than a blocked error.
    expect(calls.mutate).toHaveLength(0)
    expect(controller.snapshot().message).toContain('No hay cambios')
  })

  test('refuses the write when a protected model is forced into the removal set', async () => {
    const { api, calls } = fakeApi({ configured: [{ id: 'old' }, { id: 'gone' }], host: { provider: 'route-a', model: 'gone' }, sessionCurrent: { provider: 'route-a', model: 'old' }, discovered: [{ id: 'old' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover()
    // Bypassing the UI (which disables the box) must still hit the guard in
    // `apply`: the view is a convenience, not the enforcement point.
    controller.toggleRemove('gone')
    expect(controller.snapshot().selection.remove.has('gone')).toBe(true)
    await controller.apply()
    expect(calls.mutate).toHaveLength(0)
    expect(controller.snapshot().message).toContain('predeterminado')
  })

  test('blocks removing the model the current session is using, even when it is not the default', async () => {
    const { api, calls } = fakeApi({
      configured: [{ id: 'claude-sonnet-5' }, { id: 'claude-opus-5' }],
      host: { provider: 'route-a', model: 'claude-sonnet-5' }, sessionCurrent: { provider: 'route-a', model: 'claude-opus-5' },
      discovered: [{ id: 'claude-sonnet-5' }],
    })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover()
    // The active session model is protected independently of the host default.
    expect(controller.snapshot().selection.remove.has('claude-opus-5')).toBe(false)
    controller.toggleRemove('claude-opus-5')
    await controller.apply()
    expect(calls.mutate).toHaveLength(0)
    expect(controller.snapshot().message).toContain('claude-opus-5')
  })

  test('preserves per-model fields the plugin never adopts through the whole controller path', async () => {
    const configured = [{ id: 'keep', contextWindow: 128000, input: ['text', 'image'], reasoningEfforts: { low: 'minimal' }, compat: { maxTokensField: 'offer' } }]
    const { api, calls } = fakeApi({ configured, host: { provider: 'route-a', model: 'keep' }, sessionCurrent: { provider: 'route-a', model: 'keep' }, discovered: [{ id: 'keep', contextWindow: 999 }, { id: 'new' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover(); await controller.apply()
    expect((calls.mutate[0]?.ops[0]?.value as ModelProfile[])[0]).toEqual(configured[0])
  })

  test('refuses any removal while a protection source could not be read', async () => {
    const { api, calls } = fakeApi({ configured: [{ id: 'keep' }, { id: 'gone' }], discovered: [{ id: 'keep' }], sessionModelsFails: true })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover(); await controller.apply()
    expect(calls.mutate).toHaveLength(0)
    expect(controller.snapshot().protection.unknown).toHaveLength(1)
  })

  test('keeps diff and selection after a settings conflict', async () => {
    const { api, calls } = fakeApi({ discovered: [{ id: 'old' }, { id: 'new' }], mutateFails: true, mutateError: { code: 'settings-conflict', message: 'conflict' } })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover()
    const before = controller.snapshot()
    await controller.apply()
    expect(calls.mutate).toHaveLength(1)
    expect(controller.snapshot().diff).toEqual(before.diff)
    expect(controller.snapshot().selection).toEqual(before.selection)
    expect(controller.snapshot().message).toMatch(/recarga.*descubre/i)
  })

  test('requires an explicit acknowledgement before a bulk removal, then proceeds', async () => {
    const { api, calls } = fakeApi({ configured: [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }], host: { provider: 'route-a', model: 'a' }, sessionCurrent: { provider: 'route-a', model: 'a' }, discovered: [{ id: 'a' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover()
    expect(controller.snapshot().removalShare).toBeCloseTo(0.75)
    await controller.apply()
    expect(calls.mutate).toHaveLength(0)
    expect(controller.snapshot().message).toContain('3')
    controller.acknowledgeBulk(); await controller.apply()
    expect(calls.mutate).toHaveLength(1)
  })

  test('refuses an empty final catalog', async () => {
    const { api, calls } = fakeApi({ configured: [{ id: 'old' }], host: { provider: 'other', model: 'other' }, sessionCurrent: { provider: 'other', model: 'other' }, discovered: [{ id: 'new' }] })
    const controller = new ModelSyncController(api, 'session-1')
    await controller.load(); await controller.discover(); controller.toggleAdd('new'); await controller.apply()
    expect(calls.mutate).toHaveLength(0)
    expect(controller.snapshot().message).toMatch(/sin modelos/i)
  })
})
