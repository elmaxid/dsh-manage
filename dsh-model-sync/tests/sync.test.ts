import { describe, expect, test } from 'vitest'
import { normalizeConfiguredModels, normalizeDiscoveredModels } from '../src/sync.ts'

describe('catalog normalization', () => {
  test('drops blank ids and keeps the first configured duplicate with all metadata', () => {
    const result = normalizeConfiguredModels([
      { id: ' alpha ', contextWindow: 100, compat: { custom: true } },
      { id: '' },
      { id: 'alpha', maxTokens: 20 },
      { id: 'beta' },
    ])

    expect(result).toEqual([
      { id: 'alpha', contextWindow: 100, compat: { custom: true } },
      { id: 'beta' },
    ])
  })

  test('drops blank discovered ids and keeps endpoint order', () => {
    const result = normalizeDiscoveredModels([
      { id: 'beta', name: 'Beta' },
      { id: ' beta ', maxTokens: 20 },
      { id: '   ' },
      { id: 'alpha' },
    ])

    expect(result).toEqual([
      { id: 'beta', name: 'Beta' },
      { id: 'alpha' },
    ])
  })
})