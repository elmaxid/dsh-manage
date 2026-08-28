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