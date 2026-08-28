import type { DiscoveredModel, ModelDiff, ModelProfile, ProtectionState, SyncSelection } from '../sync.ts'

export interface ProviderView {
  provider: string
  displayName: string
  settingsNs: string
  settingsPath: string[]
  active: boolean
}

export interface NamespaceView {
  ns: string
  value: unknown
  revision: number
}

export interface RpcResult<T> {
  result: { ok: true; value: T } | { ok: false; error: { message: string; code?: string } }
}

export interface ModelSyncApi {
  llm: {
    providers(request: {}): Promise<RpcResult<{ providers: ProviderView[] }>>
    discoverModels(request: { settingsNs: string; provider?: string; baseURL?: string; api?: string }): Promise<RpcResult<{ models: DiscoveredModel[] }>>
  }
  settings: {
    describe(request: {}): Promise<RpcResult<{ writable: boolean; namespaces: NamespaceView[] }>>
    mutate(request: { ns: string; ops: Array<{ op: 'set'; path: string[]; value: unknown }>; expectedRevision?: number }): Promise<RpcResult<NamespaceView>>
  }
  host: {
    describe(request: {}): Promise<RpcResult<{ provider?: string; model?: string }>>
  }
  sessions: {
    models(request: { sessionId: string }): Promise<RpcResult<{ current?: { provider?: string; model?: string } }>>
  }
}

export type ModelSyncPhase = 'loading' | 'ready' | 'discovering' | 'diff' | 'applying' | 'success' | 'error'

export interface ModelSyncSnapshot {
  phase: ModelSyncPhase
  providers: ProviderView[]
  selectedProvider?: string
  configured: ModelProfile[]
  diff?: ModelDiff
  /**
   * Provider route the current `diff` was discovered against. `apply` refuses to
   * write when it no longer matches the selected provider, so a discovery that
   * resolves after the user switched providers can never be written into another
   * provider's settings path.
   */
  diffProvider?: string
  selection: SyncSelection
  writable: boolean
  protection: ProtectionState
  removalShare: number
  bulkAcknowledged: boolean
  message?: string
}
