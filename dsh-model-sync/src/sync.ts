export interface ModelProfile {
  id: string
  [key: string]: unknown
}

export interface DiscoveredModel {
  id: string
  name?: string
  contextWindow?: number
  maxTokens?: number
}

function normalize<T extends { id: string }>(models: readonly T[]): T[] {
  const seen = new Set<string>()
  const result: T[] = []
  for (const model of models) {
    const id = model.id.trim()
    if (id.length === 0 || seen.has(id)) continue
    seen.add(id)
    result.push({ ...model, id })
  }
  return result
}

export const normalizeConfiguredModels = (models: readonly ModelProfile[]): ModelProfile[] => normalize(models)
export const normalizeDiscoveredModels = (models: readonly DiscoveredModel[]): DiscoveredModel[] => normalize(models)

export interface ModelDiff {
  configured: ModelProfile[]
  discovered: DiscoveredModel[]
  newModels: DiscoveredModel[]
  existing: Array<{ configured: ModelProfile; discovered: DiscoveredModel }>
  missing: ModelProfile[]
}

export interface SyncSelection {
  add: Set<string>
  remove: Set<string>
}

/** One model that must survive the write, and why. */
export interface ModelProtection {
  provider: string
  model: string
  reason: 'host-default' | 'active-session'
}

/** What is protected, and which sources could not be read. */
export interface ProtectionState {
  known: ModelProtection[]
  /** A source that failed or answered nothing. Non-empty forbids every removal. */
  unknown: Array<{ reason: 'host-default' | 'active-session'; detail: string }>
}

export interface SettingsMutation { op: 'set'; path: string[]; value: ModelProfile[] }

export function diffModels(
  configured: readonly ModelProfile[],
  discovered: readonly DiscoveredModel[],
): ModelDiff {
  const normalizedConfigured = normalizeConfiguredModels(configured)
  const normalizedDiscovered = normalizeDiscoveredModels(discovered)
  const configuredById = new Map(normalizedConfigured.map(model => [model.id, model]))
  const discoveredIds = new Set(normalizedDiscovered.map(model => model.id))
  const newModels: DiscoveredModel[] = []
  const existing: ModelDiff['existing'] = []

  for (const candidate of normalizedDiscovered) {
    const local = configuredById.get(candidate.id)
    if (local === undefined) newModels.push(candidate)
    else existing.push({ configured: local, discovered: candidate })
  }

  return {
    configured: normalizedConfigured,
    discovered: normalizedDiscovered,
    newModels,
    existing,
    missing: normalizedConfigured.filter(model => !discoveredIds.has(model.id)),
  }
}

export function defaultSelection(diff: ModelDiff): SyncSelection {
  if (diff.discovered.length === 0) return { add: new Set(), remove: new Set() }
  return {
    add: new Set(diff.newModels.map(model => model.id)),
    remove: new Set(diff.missing.map(model => model.id)),
  }
}

export function buildFinalModels(diff: ModelDiff, selection: SyncSelection): ModelProfile[] {
  const configuredById = new Map(diff.configured.map(model => [model.id, model]))
  const newById = new Map(diff.newModels.map(model => [model.id, model]))
  const result: ModelProfile[] = []

  for (const discovered of diff.discovered) {
    const configured = configuredById.get(discovered.id)
    if (configured !== undefined) {
      result.push(configured)
      continue
    }
    const candidate = newById.get(discovered.id)
    if (candidate === undefined || !selection.add.has(discovered.id)) continue
    const adopted: ModelProfile = { id: candidate.id }
    if (candidate.name !== undefined) adopted.name = candidate.name
    if (candidate.contextWindow !== undefined) adopted.contextWindow = candidate.contextWindow
    if (candidate.maxTokens !== undefined) adopted.maxTokens = candidate.maxTokens
    result.push(adopted)
  }

  for (const missing of diff.missing) {
    if (!selection.remove.has(missing.id)) result.push(missing)
  }

  return normalizeConfiguredModels(result)
}

export function blockedRemovals(
  provider: string,
  finalModels: readonly ModelProfile[],
  protection: ProtectionState,
  configured?: readonly ModelProfile[],
): ModelProtection[] {
  const finalIds = new Set(normalizeConfiguredModels(finalModels).map(model => model.id))
  const blocked = protection.known.filter(
    entry => entry.provider === provider && !finalIds.has(entry.model.trim()),
  )

  const removesConfigured = configured === undefined
    || normalizeConfiguredModels(configured).some(model => !finalIds.has(model.id))
  if (!removesConfigured) return blocked

  for (const unknown of protection.unknown) {
    blocked.push({ provider, model: unknown.detail, reason: unknown.reason })
  }
  return blocked
}

export function hasNoChanges(
  configured: readonly ModelProfile[],
  finalModels: readonly ModelProfile[],
): boolean {
  if (configured.length !== finalModels.length) return false
  return configured.every((model, index) => {
    const finalModel = finalModels[index]
    return finalModel !== undefined
      && model.id === finalModel.id
      && JSON.stringify(model) === JSON.stringify(finalModel)
  })
}

export function bulkRemovalShare(
  configured: readonly ModelProfile[],
  finalModels: readonly ModelProfile[],
): number {
  const normalizedConfigured = normalizeConfiguredModels(configured)
  if (normalizedConfigured.length === 0) return 0
  const finalIds = new Set(normalizeConfiguredModels(finalModels).map(model => model.id))
  const removed = normalizedConfigured.filter(model => !finalIds.has(model.id)).length
  return removed / normalizedConfigured.length
}

export function modelsMutation(
  settingsPath: readonly string[],
  models: readonly ModelProfile[],
): SettingsMutation {
  if (settingsPath.length === 0) throw new Error('settings path must address a provider profile')
  return { op: 'set', path: [...settingsPath, 'models'], value: [...models] }
}