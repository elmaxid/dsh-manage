import { describe, expect, test } from 'vitest'
import {
  blockedRemovals,
  buildFinalModels,
  bulkRemovalShare,
  defaultSelection,
  diffModels,
  hasNoChanges,
  modelsMutation,
  normalizeConfiguredModels,
  normalizeDiscoveredModels,
} from '../src/sync.ts'

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

test('classifies endpoint additions, shared models, and missing configured models', () => {
  const diff = diffModels(
    [{ id: 'shared', compat: { local: true } }, { id: 'gone' }],
    [{ id: 'new', maxTokens: 99 }, { id: 'shared', maxTokens: 50 }],
  )

  expect(diff.newModels.map(model => model.id)).toEqual(['new'])
  expect(diff.existing.map(model => model.configured.id)).toEqual(['shared'])
  expect(diff.missing.map(model => model.id)).toEqual(['gone'])
})

test('selects additions and removals by default only for a non-empty discovery', () => {
  const diff = diffModels([{ id: 'gone' }], [{ id: 'new' }])
  expect(defaultSelection(diff)).toEqual({ add: new Set(['new']), remove: new Set(['gone']) })

  const empty = diffModels([{ id: 'keep' }], [])
  expect(defaultSelection(empty)).toEqual({ add: new Set(), remove: new Set() })
})

test('builds endpoint order, preserves local metadata, adopts new metadata, and appends kept missing models', () => {
  const diff = diffModels(
    [
      { id: 'shared', contextWindow: 100, compat: { local: true } },
      { id: 'kept-missing', maxTokens: 7 },
      { id: 'removed' },
    ],
    [
      { id: 'new', name: 'New', contextWindow: 200, maxTokens: 20 },
      { id: 'shared', contextWindow: 999, maxTokens: 999 },
    ],
  )

  const result = buildFinalModels(diff, {
    add: new Set(['new']),
    remove: new Set(['removed']),
  })
  expect(result).toEqual([
    { id: 'new', name: 'New', contextWindow: 200, maxTokens: 20 },
    { id: 'shared', contextWindow: 100, compat: { local: true } },
    { id: 'kept-missing', maxTokens: 7 },
  ])
})

test('blocks removing a protected model, scoped to the matching provider', () => {
  const protection = {
    known: [
      { provider: 'route-a', model: 'the-default', reason: 'host-default' as const },
      { provider: 'route-a', model: 'in-use', reason: 'active-session' as const },
    ],
    unknown: [],
  }

  expect(blockedRemovals('route-a', [{ id: 'other' }], protection).map(p => p.model))
    .toEqual(['the-default', 'in-use'])
  expect(blockedRemovals('route-a', [{ id: 'the-default' }, { id: 'in-use' }], protection))
    .toEqual([])
  expect(blockedRemovals('route-b', [{ id: 'other' }], protection)).toEqual([])
})

test('blocks every removal while a protection source is unreadable', () => {
  const protection = {
    known: [],
    unknown: [{ reason: 'active-session' as const, detail: 'session.models failed' }],
  }

  expect(blockedRemovals('route-a', [{ id: 'kept' }], protection, [{ id: 'kept' }, { id: 'dropped' }]))
    .toHaveLength(1)
  expect(blockedRemovals('route-a', [{ id: 'kept' }], protection, [{ id: 'kept' }]))
    .toEqual([])
})

test('creates one set mutation at the provider models path', () => {
  expect(modelsMutation(['providers', 'route-a'], [{ id: 'alpha' }])).toEqual({
    op: 'set',
    path: ['providers', 'route-a', 'models'],
    value: [{ id: 'alpha' }],
  })
})

test('refuses an empty settings path that would address the whole section', () => {
  expect(() => modelsMutation([], [{ id: 'alpha' }])).toThrow(/settings path/i)
})

test('reports the share of the configured catalog a write would remove', () => {
  const configured = [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }]

  expect(bulkRemovalShare(configured, configured)).toBe(0)
  expect(bulkRemovalShare(configured, [{ id: 'a' }, { id: 'b' }, { id: 'c' }])).toBeCloseTo(0.25)
  expect(bulkRemovalShare(configured, [{ id: 'a' }])).toBeCloseTo(0.75)
  expect(bulkRemovalShare(configured, [...configured, { id: 'e' }])).toBe(0)
  expect(bulkRemovalShare([], [{ id: 'a' }])).toBe(0)
})

test('detects an unchanged catalog by id and order', () => {
  const configured = [{ id: 'a', contextWindow: 10 }, { id: 'b' }]
  expect(hasNoChanges(configured, [{ id: 'a', contextWindow: 10 }, { id: 'b' }])).toBe(true)
  expect(hasNoChanges(configured, [{ id: 'b' }, { id: 'a', contextWindow: 10 }])).toBe(false)
  expect(hasNoChanges(configured, [{ id: 'a', contextWindow: 10 }])).toBe(false)
})