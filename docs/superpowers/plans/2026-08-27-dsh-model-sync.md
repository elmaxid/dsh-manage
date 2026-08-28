# DSH Model Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an installable `dsh-model-sync` bundle that adds a Models tab beside Chat, discovers the configured provider's current model catalog, previews additions/removals with checkboxes, and safely persists the selected final list.

**Architecture:** A small Host entry makes the npm package a normal DSH bundle; all product interaction occurs in the Client through the existing `connection.api` domains. Pure catalog comparison and mutation construction live in shared modules with test-first coverage. The Client controller reads `llm.providers`, `settings.describe`, `host.describe` and `sessions.models`, calls `llm.discoverModels`, and writes one revision-guarded `settings.mutate` operation; the React view only renders controller state and dispatches actions.

**Tech Stack:** TypeScript, React 18 without JSX runtime assumptions, Cordis Client slots, DSH Host API proxy (`llm`, `settings`, `host`), tsdown, Vitest, pnpm.

**Spec:** `docs/superpowers/specs/2026-08-27-dsh-model-sync-design.md`

## Global Constraints

- Register an additive `conversation.view` entry with id `models-sync`; never replace `conversation`, `conversation.session`, or a shipped view id.
- Use only the official `connection.api` domains; never read or write `settings.yaml` directly and never add a custom HTTP endpoint.
- Modify only the provider profile's `models` path through one `settings.mutate` call with `expectedRevision`.
- Endpoint discovery is authoritative only after a non-empty successful response; an empty result never automatically removes models.
- Preserve every local field of an existing model; adopt only `id`, `name`, `contextWindow`, and `maxTokens` for a new model.
- New models are selected for addition by default; missing models are selected for removal by default.
- Block a write that removes a protected model: the Host default, or the model the current session is using. These are not the same model — this deployment defaults to `claude-sonnet-5` while running `claude-opus-5`.
- Treat a protection source that could not be read as *unknown*, never as *nothing to protect*: while any source is unreadable, refuse every removal (additions stay allowed).
- Keep the discovery diff and selections after a write failure so the user can retry.
- No runtime dependency on a new visual framework; use React and DSH theme CSS variables.
- Installation in the real `web` profile occurs only after security scanning, isolated test-drive success, and explicit user approval.

---

## File Map

- `dsh-model-sync/package.json` — npm metadata, bundle/client declarations, scripts, dependency contracts.
- `dsh-model-sync/cordis.patch.yml` — inserts the single Host plugin row.
- `dsh-model-sync/tsconfig.json` — strict Node-side typecheck for `src/sync.ts`, `src/index.ts` and `tests`.
- `dsh-model-sync/tsconfig.client.json` — browser-side typecheck for `src/client`, without `types: ["node"]` so the bundle's own `require` declaration does not collide with `@types/node`.
- `dsh-model-sync/tsdown.config.mjs` — builds Host ESM and Client browser closure bundle.
- `dsh-model-sync/src/index.ts` — minimal Host Cordis entry and public pure-helper exports.
- `dsh-model-sync/src/sync.ts` — normalization, diffing, selection defaults, final catalog, default-model guard, settings mutation.
- `dsh-model-sync/src/client/types.ts` — narrow JSON/wire/UI state contracts owned by this plugin.
- `dsh-model-sync/src/client/controller.ts` — provider/settings loading, discovery, selection and revision-safe apply workflow.
- `dsh-model-sync/src/client/register.ts` — additive `conversation.view` registration, independently testable without browser globals.
- `dsh-model-sync/src/client/react.ts` — typed injected `require('react')` bridge.
- `dsh-model-sync/src/client/ModelSyncView.ts` — React component rendered with `React.createElement`.
- `dsh-model-sync/src/client/index.ts` — Client Cordis entry.
- `dsh-model-sync/src/client/styles.css` — scoped `.dms-*` theme-aware styles.
- `dsh-model-sync/src/client/globals.d.ts` — closure-bundle globals and CSS import declaration.
- `dsh-model-sync/tests/sync.test.ts` — pure synchronization policy tests.
- `dsh-model-sync/tests/controller.test.ts` — real controller behavior against a small fake wire API.
- `dsh-model-sync/tests/register.test.ts` — verifies additive slot registration and disposer ownership.
- `dsh-model-sync/tests/manifest.test.ts` — package/patch/client build contract.
- `dsh-model-sync/README.md` — installation, behavior, safeguards, development and limitations.

---

### Task 1: Scaffold the Bundle and Implement Catalog Normalization

**Files:**
- Create: `dsh-model-sync/package.json`
- Create: `dsh-model-sync/cordis.patch.yml`
- Create: `dsh-model-sync/tsconfig.json`
- Create: `dsh-model-sync/tsdown.config.mjs`
- Create: `dsh-model-sync/src/index.ts`
- Create: `dsh-model-sync/src/sync.ts`
- Create: `dsh-model-sync/tests/sync.test.ts`

**Interfaces:**
- Produces: `ModelProfile`, `DiscoveredModel`, `normalizeConfiguredModels(models)`, `normalizeDiscoveredModels(models)` from `src/sync.ts`.
- Later tasks consume normalized arrays containing non-empty unique `id` values in first-seen order.

- [ ] **Step 1: Create the package scaffolding needed to run tests**

Create `dsh-model-sync/package.json` with this contract:

```json
{
  "name": "dsh-model-sync",
  "version": "0.1.0",
  "description": "Synchronize configured DSH models with a provider endpoint from a conversation tab.",
  "type": "module",
  "main": "lib/index.js",
  "types": "lib/index.d.ts",
  "exports": {
    ".": {
      "types": "./lib/index.d.ts",
      "default": "./lib/index.js"
    },
    "./client": "./lib/client.js",
    "./package.json": "./package.json"
  },
  "files": ["lib", "cordis.patch.yml", "README.md", "LICENSE"],
  "scripts": {
    "build": "tsdown",
    "typecheck": "tsc --noEmit && tsc --noEmit -p tsconfig.client.json",
    "test": "vitest run",
    "verify": "pnpm run typecheck && pnpm run test && pnpm run build",
    "prepare": "tsdown"
  },
  "dsh": {
    "bundle": { "patch": "./cordis.patch.yml" },
    "client": {
      "inject": [
        "@deepseek-ai/dsh-client-connection",
        "@deepseek-ai/dsh-client-runtime",
        "@deepseek-ai/dsh-client-ui-conversation"
      ],
      "platform": "web"
    }
  },
  "peerDependencies": {
    "@deepseek-ai/cordis": "^4.0.1",
    "react": "^18.3.1"
  },
  "peerDependenciesMeta": {
    "react": { "optional": true }
  },
  "devDependencies": {
    "@deepseek-ai/cordis": "^4.0.1",
    "@types/node": "^22.20.1",
    "@types/react": "^18.3.31",
    "react": "^18.3.1",
    "tsdown": "^0.22.14",
    "typescript": "^5.9.3",
    "vitest": "^3.2.7"
  },
  "engines": { "node": ">=22.19.0" },
  "license": "Apache-2.0",
  "packageManager": "pnpm@11.7.0"
}
```

Create `cordis.patch.yml`:

```yaml
- insert:
    - id: dsh-model-sync
      name: dsh-model-sync
```

Create two typecheck configurations, because the two halves have incompatible global environments. Both files below were verified by running `tsc` against source copied verbatim from this plan; the chain `tsc --noEmit && tsc --noEmit -p tsconfig.client.json` exits 0. Copy them exactly — every field is load-bearing.

`tsconfig.json` — Node side:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022"],
    "types": ["node"],
    "strict": true,
    "noEmit": true,
    "allowImportingTsExtensions": true
  },
  "include": ["src/index.ts", "src/sync.ts", "tests"]
}
```

`tsconfig.client.json` — browser side:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM"],
    "types": [],
    "strict": true,
    "noEmit": true,
    "allowImportingTsExtensions": true
  },
  "include": ["src/client"]
}
```

Two fields exist for reasons that are easy to get backwards:

**`allowImportingTsExtensions` is required in BOTH files.** Every import in this plan carries an explicit `.ts` extension (Task 1 `export * from './sync.ts'`, the test imports, and the client's `../sync.ts`). Without the flag `tsc` refuses them outright with `TS5097: An import path can only end with a '.ts' extension when 'allowImportingTsExtensions' is enabled`, and the typecheck can never pass. The flag itself requires `noEmit`, which both files set — tsdown does the emitting, `tsc` only checks.

**`"types": []` on the client is required, and is NOT the same as omitting the field.** Omitting `types` makes TypeScript implicitly include every package under `node_modules/@types`, which pulls in `@types/node` — the exact opposite of what the client needs. Its ambient `var require`, `var module` and `var exports` then collide with the closure bundle's own declarations in `globals.d.ts`, producing `TS2300: Duplicate identifier 'require'` plus two `TS2451` redeclaration errors. A `function` declaration does not merge with a `var` declaration, so this is a hard failure, not a warning. Only an explicit empty array suppresses implicit type-library inclusion. Do not reach for `skipLibCheck: true` instead: it silences the errors by skipping type-checking of your own `globals.d.ts` as well, leaving a real global-scope conflict live in the build.

Create a dual-entry `tsdown.config.mjs` based on the verified `dsh-context` pattern:

- Host: `src/index.ts` → `lib/index.js`, ESM, Node 22, DTS, clean output.
- Client: `src/client/index.ts` → `lib/client.js`, CJS/browser, no DTS, `clean: false`.
- Client externals: `react`, `@deepseek-ai/cordis`, and `@deepseek-ai/dsh-client-runtime/client`.
- The CSS plugin inlines the stylesheet verbatim into a `document.head` style tag. Do NOT add `lightningcss` or any other CSS toolchain: the stylesheet is small and hand-written, and minification is not worth a build dependency.
- Client wrapper:

```js
banner: `window.__ModuleLoader__.load({ id: ${JSON.stringify(pkg.name)}, factory: (require) => {`,
intro: 'var module = { exports: {} }; var exports = module.exports;',
footer: 'return module.exports; } });',
```

- [ ] **Step 2: Install only the package development dependencies**

Run:

```bash
cd /opt/dsh-manage/dsh-model-sync
pnpm install --ignore-scripts
```

Expected: exit code 0 and a lockfile owned by this plugin. Do not install the bundle into a DSH profile.

- [ ] **Step 3: Write failing normalization tests**

Create `tests/sync.test.ts`:

```ts
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
```

- [ ] **Step 4: Run the tests and verify RED**

Run:

```bash
pnpm test -- tests/sync.test.ts
```

Expected: FAIL because `src/sync.ts` and the normalization exports do not exist.

- [ ] **Step 5: Implement the minimum normalization code**

Create `src/sync.ts` with JSON-safe types and one internal normalizer:

```ts
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
```

Create `src/index.ts`:

```ts
export const name = 'dsh-model-sync'
export function apply(): void {}
export * from './sync.ts'
```

- [ ] **Step 6: Run tests and typecheck to verify GREEN**

Run:

```bash
pnpm test -- tests/sync.test.ts
pnpm typecheck
```

Expected: both commands exit 0.

- [ ] **Step 7: Commit the scaffold and normalization policy**

```bash
git add dsh-model-sync
git commit -m "feat: scaffold model sync bundle"
```

---

### Task 2: Implement Diffing, Selection Defaults, Final Catalog, and Safety Guard

**Files:**
- Modify: `dsh-model-sync/src/sync.ts`
- Modify: `dsh-model-sync/tests/sync.test.ts`

**Interfaces:**
- Consumes: normalized `ModelProfile[]` and `DiscoveredModel[]` from Task 1.
- Produces:
  - `diffModels(configured, discovered): ModelDiff`
  - `defaultSelection(diff): SyncSelection`
  - `buildFinalModels(diff, selection): ModelProfile[]`
  - `blockedRemovals(provider, finalModels, protection, configured?): ModelProtection[]`
  - `hasNoChanges(configured, finalModels): boolean`
  - `modelsMutation(settingsPath, models): SettingsMutation` (throws on an empty path)

Note there is no `removesDefaultModel`. Guarding only the Host default is not sufficient: the Host default and the model a live session is actually using are different things, and this deployment demonstrates the gap — the configured default is `claude-sonnet-5` while an active session runs `claude-opus-5`. A guard that checked only the default would happily delete the model the user is talking to right now. `blockedRemovals` replaces it and covers both sources plus the unreadable-source case.

- [ ] **Step 1: Write failing diff and default-selection tests**

Append tests:

```ts
import {
  blockedRemovals,
  buildFinalModels,
  defaultSelection,
  diffModels,
  hasNoChanges,
  modelsMutation,
} from '../src/sync.ts'

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
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
pnpm test -- tests/sync.test.ts
```

Expected: FAIL because the new exports do not exist.

- [ ] **Step 3: Implement diff and selection defaults**

Add these exact public shapes:

```ts
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
```

`diffModels` must normalize inputs, compare exact trimmed IDs, preserve endpoint order in `newModels`/`existing`, and local order in `missing`. `defaultSelection` returns empty sets when `diff.discovered.length === 0`; otherwise it selects every new and missing ID.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run `pnpm test -- tests/sync.test.ts`.

Expected: PASS.

- [ ] **Step 5: Write failing final-catalog, metadata and guard tests**

Append:

```ts
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

  // Both protected models are gone from the final list: both are reported.
  expect(blockedRemovals('route-a', [{ id: 'other' }], protection).map(p => p.model))
    .toEqual(['the-default', 'in-use'])

  // Keeping them clears the block.
  expect(blockedRemovals('route-a', [{ id: 'the-default' }, { id: 'in-use' }], protection))
    .toEqual([])

  // A protection for another provider must not block this one.
  expect(blockedRemovals('route-b', [{ id: 'other' }], protection)).toEqual([])
})

test('blocks every removal while a protection source is unreadable', () => {
  const protection = {
    known: [],
    unknown: [{ reason: 'active-session' as const, detail: 'session.models failed' }],
  }

  // Removing anything is refused: an unreadable source is unknown, not "nothing to protect".
  expect(blockedRemovals('route-a', [{ id: 'kept' }], protection, [{ id: 'kept' }, { id: 'dropped' }]))
    .toHaveLength(1)

  // Removing nothing is still allowed, so pure additions never get stuck.
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
  // `settingsPath: []` means "the whole namespace section", so appending
  // 'models' would write to a top-level key belonging to no provider.
  expect(() => modelsMutation([], [{ id: 'alpha' }])).toThrow(/settings path/i)
})

test('detects an unchanged catalog by id and order', () => {
  const configured = [{ id: 'a', contextWindow: 10 }, { id: 'b' }]
  expect(hasNoChanges(configured, [{ id: 'a', contextWindow: 10 }, { id: 'b' }])).toBe(true)
  expect(hasNoChanges(configured, [{ id: 'b' }, { id: 'a', contextWindow: 10 }])).toBe(false)
  expect(hasNoChanges(configured, [{ id: 'a', contextWindow: 10 }])).toBe(false)
})
```

- [ ] **Step 6: Run tests and verify RED for final-catalog behavior**

Expected: FAIL on missing exports.

- [ ] **Step 7: Implement final catalog, guard, and mutation helpers**

Rules in `buildFinalModels`:

1. Walk `diff.discovered` in endpoint order.
2. For an existing ID, push its full configured object.
3. For a new ID, push it only when `selection.add` contains it, using only the candidate fields `id`, `name`, `contextWindow`, `maxTokens` that are defined.
4. Walk `diff.missing` in local order and append each ID not present in `selection.remove`.
5. Return a normalized unique array.

Define:

```ts
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
```

`blockedRemovals(provider, finalModels, protection, configured?)` returns the protections the write would violate, empty when the write is safe:

1. For each entry in `protection.known` whose `provider` matches, report it when `finalModels` lacks that exact model id.
2. When `protection.unknown` is non-empty **and** the write removes at least one configured model, report a synthetic protection per unknown source. Determining "removes at least one" needs the `configured` list, which is why it is the fourth parameter; when omitted, treat any unknown source as blocking.
3. A write that removes nothing is never blocked, so a pure addition still works while a source is down.

Rule 2 is the spec's requirement that an unreadable source is never read as permission to delete. A failed `session.models` or `host.describe` call means *unknown*, not *nothing to protect* — the difference between those two readings is whether the plugin can silently delete the model the user is currently using.

`hasNoChanges` compares the configured list against the final list by length, then by index-aligned `id`, then by deep JSON equality of each entry; it reports true only when the write would be a no-op.

`modelsMutation` throws `new Error('settings path must address a provider profile')` when `settingsPath.length === 0`, and otherwise appends `'models'` to a copied `settingsPath`.

- [ ] **Step 8: Run all sync tests and typecheck**

```bash
pnpm test -- tests/sync.test.ts
pnpm typecheck
```

Expected: PASS with no warnings.

- [ ] **Step 9: Commit the synchronization policy**

```bash
git add dsh-model-sync/src/sync.ts dsh-model-sync/tests/sync.test.ts
git commit -m "feat: implement model synchronization policy"
```

---

### Task 3: Implement the Wire Controller with Revision-Safe Writes

**Files:**
- Create: `dsh-model-sync/src/client/types.ts`
- Create: `dsh-model-sync/src/client/controller.ts`
- Create: `dsh-model-sync/tests/controller.test.ts`

**Interfaces:**
- Consumes: `diffModels`, `defaultSelection`, `buildFinalModels`, `blockedRemovals`, `hasNoChanges`, `modelsMutation`.
- Produces: `ModelSyncController` with methods `load()`, `selectProvider(id)`, `discover()`, `toggleAdd(id)`, `toggleRemove(id)`, `apply()`, `snapshot()` and `subscribe(listener)`.
- Produces immutable `ModelSyncSnapshot` values for React `useSyncExternalStore`.

**Two hard requirements, both of which crash the tab if missed:**

1. **`snapshot()` must return a cached, referentially stable object.** It returns the identical object reference on every call until a real transition replaces it. `useSyncExternalStore` compares snapshots by identity; returning a freshly built object each call is an infinite render loop, not a performance detail.
2. **`snapshot` and `subscribe` must be arrow-function class properties**, not prototype methods. The view passes them as bare references (`useSyncExternalStore(controller.subscribe, controller.snapshot, ...)`); prototype methods lose `this` and throw on first render.

- [ ] **Step 1: Define narrow wire and state contracts**

Create `src/client/types.ts` containing only JSON-owned fields needed by the plugin:

```ts
import type { DiscoveredModel, ModelDiff, ModelProfile, SyncSelection } from '../sync.ts'

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
    discoverModels(request: {
      settingsNs: string
      provider?: string
      baseURL?: string
      api?: string
    }): Promise<RpcResult<{ models: DiscoveredModel[] }>>
  }
  settings: {
    describe(request: {}): Promise<RpcResult<{ writable: boolean; namespaces: NamespaceView[] }>>
    mutate(request: {
      ns: string
      ops: Array<{ op: 'set'; path: string[]; value: unknown }>
      expectedRevision?: number
    }): Promise<RpcResult<NamespaceView>>
  }
  host: {
    describe(request: {}): Promise<RpcResult<{ provider?: string; model?: string }>>
  }
  sessions: {
    /** The model this session will use for its next step. */
    models(request: { sessionId: string }): Promise<RpcResult<{
      current?: { provider?: string; model?: string }
    }>>
  }
}

export type ModelSyncPhase = 'loading' | 'ready' | 'discovering' | 'diff' | 'applying' | 'success' | 'error'

export interface ModelSyncSnapshot {
  phase: ModelSyncPhase
  providers: ProviderView[]
  selectedProvider?: string
  configured: ModelProfile[]
  diff?: ModelDiff
  selection: SyncSelection
  writable: boolean
  protection: ProtectionState
  message?: string
}
```

Add internal helpers `unwrap`, `objectAtPath`, and `profileFrom(namespace, provider)` in `controller.ts`; they must copy only leaf JSON fields used by the plugin.

- [ ] **Step 2: Write failing controller load/discovery tests**

Create a fake API with call recording and tests:

```ts
test('loads configurable providers, settings profile, revision, and host default', async () => {
  const api = fakeApi({
    providers: [{ provider: 'route-a', displayName: 'Route A', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-a'], active: true }],
    namespaces: [{ ns: 'llm-pi-ai', revision: 4, value: { providers: { 'route-a': { api: 'openai-completions', baseURL: 'https://example.test/v1', models: [{ id: 'old' }] } } } }],
    host: { provider: 'route-a', model: 'old' },
    sessionCurrent: { provider: 'route-a', model: 'old' },
  })
  const controller = new ModelSyncController(api, 'session-1')

  await controller.load()

  expect(controller.snapshot()).toMatchObject({
    phase: 'ready',
    selectedProvider: 'route-a',
    configured: [{ id: 'old' }],
  })
  expect(controller.snapshot().protection.known).toContainEqual({
    provider: 'route-a', model: 'old', reason: 'host-default',
  })
  expect(controller.snapshot().protection.unknown).toEqual([])
})

test('discovers with the provider settings address and creates default selections', async () => {
  const { api, calls } = readyFakeApi({ discovered: [{ id: 'new' }] })
  const controller = new ModelSyncController(api, 'session-1')
  await controller.load()
  await controller.discover()

  expect(calls.discover[0]).toEqual({
    settingsNs: 'llm-pi-ai',
    provider: 'route-a',
    baseURL: 'https://example.test/v1',
    api: 'openai-completions',
  })
  expect(controller.snapshot().selection.add).toEqual(new Set(['new']))
})

test('returns a referentially stable snapshot between transitions', async () => {
  const controller = new ModelSyncController(readyFakeApi({}).api, 'session-1')
  await controller.load()

  // Identity stability is what keeps useSyncExternalStore from looping.
  expect(controller.snapshot()).toBe(controller.snapshot())

  const before = controller.snapshot()
  await controller.discover()
  expect(controller.snapshot()).not.toBe(before)
})

test('exposes snapshot and subscribe as detachable references', async () => {
  const controller = new ModelSyncController(readyFakeApi({}).api, 'session-1')
  // The view passes these as bare references; they must not need `this`.
  const { snapshot, subscribe } = controller

  expect(() => snapshot()).not.toThrow()
  const unsubscribe = subscribe(() => {})
  await controller.load()
  expect(snapshot().phase).toBe('ready')
  unsubscribe()
})

test('discards a diff belonging to another provider when the selection changes', async () => {
  const { api } = readyFakeApi({
    providers: [
      { provider: 'route-a', displayName: 'A', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-a'], active: true },
      { provider: 'route-b', displayName: 'B', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'route-b'], active: true },
    ],
    discovered: [{ id: 'from-a' }],
  })
  const controller = new ModelSyncController(api, 'session-1')
  await controller.load()
  await controller.discover()
  expect(controller.snapshot().diff).toBeDefined()

  controller.selectProvider('route-b')

  // Applying route-a's catalog onto route-b would corrupt the profile.
  expect(controller.snapshot().diff).toBeUndefined()
  expect(controller.snapshot().selection).toEqual({ add: new Set(), remove: new Set() })
})
```

- [ ] **Step 3: Run controller tests and verify RED**

Run `pnpm test -- tests/controller.test.ts`.

Expected: FAIL because `ModelSyncController` does not exist.

- [ ] **Step 4: Implement load, provider selection, discovery, and subscriptions**

Implementation requirements:

- The controller is constructed as `new ModelSyncController(api, sessionId)`. The `sessionId` comes from the slot's standard props — `conversation.view` is session-scoped and already supplies it, so no extra plumbing is needed.
- `load()` calls `llm.providers`, `settings.describe`, `host.describe` and `sessions.models({ sessionId })` concurrently, then folds the last two into one `ProtectionState`:
  - `host.describe` returning both `provider` and `model` contributes a `host-default` protection; a failed call, or a reply missing either field, contributes an `unknown` entry instead.
  - `sessions.models` returning `current.provider` and `current.model` contributes an `active-session` protection; a failed call contributes an `unknown` entry.
  - Never collapse a failure into "no protection". That distinction is the whole point of `ProtectionState`.
- Keep only providers that satisfy all three conditions: a matching `settingsNs` descriptor exists, `settingsPath` is non-empty, and the addressed profile is a plain object. A provider with an empty `settingsPath` addresses the whole section and cannot be written safely, so it is filtered out here rather than failing later at write time.
- Prefer the previously selected provider; otherwise first `active` provider; otherwise first provider.
- `selectProvider(id)` changes the provider and, whenever the id actually differs, clears `diff` and resets `selection` to empty sets, returning to `phase: 'ready'`. A diff is only valid for the provider it was discovered against.
- Preserve the namespace revision and provider draft privately in the controller. Cache the published snapshot and replace it only on a real transition.
- `discover()` sends `settingsNs`, `provider`, and optional string `baseURL`/`api`.
- An empty successful discovery sets `phase: 'error'`, `message: 'El endpoint no anunció modelos; no se aplicará ninguna eliminación.'`, and leaves `diff` undefined.
- A failed RPC sets `phase: 'error'` without altering configured models.
- Every transition publishes a newly allocated snapshot object.

- [ ] **Step 5: Run controller tests and verify GREEN**

Run `pnpm test -- tests/controller.test.ts`.

Expected: PASS.

- [ ] **Step 6: Write failing apply, retry, conflict, and default-model tests**

Add tests proving:

```ts
test('writes exactly one revision-guarded models mutation and reloads after success', async () => {
  // load old; discover old + new; apply
  expect(calls.mutate).toEqual([{
    ns: 'llm-pi-ai',
    ops: [{ op: 'set', path: ['providers', 'route-a', 'models'], value: [{ id: 'old' }, { id: 'new' }] }],
    expectedRevision: 4,
  }])
  expect(controller.snapshot().phase).toBe('success')
})

test('blocks applying a catalog that removes the host default model', async () => {
  // configured default is missing remotely and remains selected for removal
  await controller.apply()
  expect(calls.mutate).toHaveLength(0)
  expect(controller.snapshot().message).toContain('predeterminado')
})

test('blocks removing the model the current session is using, even when it is not the default', async () => {
  // Mirrors the real deployment: default is claude-sonnet-5, this session runs
  // claude-opus-5. A default-only guard would delete the model in active use.
  const { api, calls } = readyFakeApi({
    configured: [{ id: 'claude-sonnet-5' }, { id: 'claude-opus-5' }],
    host: { provider: 'route-a', model: 'claude-sonnet-5' },
    sessionCurrent: { provider: 'route-a', model: 'claude-opus-5' },
    discovered: [{ id: 'claude-sonnet-5' }],
  })
  const controller = new ModelSyncController(api, 'session-1')
  await controller.load()
  await controller.discover()
  await controller.apply()

  expect(calls.mutate).toHaveLength(0)
  expect(controller.snapshot().message).toContain('claude-opus-5')
})

test('refuses any removal while a protection source could not be read', async () => {
  const { api, calls } = readyFakeApi({
    configured: [{ id: 'keep' }, { id: 'gone' }],
    discovered: [{ id: 'keep' }],
    sessionModelsFails: true,
  })
  const controller = new ModelSyncController(api, 'session-1')
  await controller.load()
  await controller.discover()
  await controller.apply()

  expect(calls.mutate).toHaveLength(0)
  expect(controller.snapshot().protection.unknown).toHaveLength(1)
})

test('keeps diff and selection after mutate failure', async () => {
  // mutate returns ok:false
  const before = controller.snapshot()
  await controller.apply()
  expect(controller.snapshot().diff).toEqual(before.diff)
  expect(controller.snapshot().selection).toEqual(before.selection)
})
```

Also test that `toggleAdd` and `toggleRemove` copy the corresponding sets rather than mutating a published snapshot.

- [ ] **Step 7: Run tests and verify RED for apply behavior**

Expected: FAIL on unimplemented apply/toggle behavior.

- [ ] **Step 8: Implement apply and immutable selection toggles**

`apply()` must:

1. Require a selected provider, addressed namespace, non-empty diff and writable settings.
2. Build final models from current selection.
3. Refuse an empty final list, publishing a message explaining that a provider without models is unusable and at least one must be kept.
4. Call `blockedRemovals(provider, finalModels, protection, configured)` and refuse when it returns anything, naming each blocking model and its reason: the Host default, the model this session is using, or a protection source that could not be read. Tell the user what to do — keep the model, or change the default/session model first.
5. When `hasNoChanges(configured, finalModels)` is true, publish `phase: 'success'` with a "no changes" message and send no mutation at all.
6. Send exactly one `settings.mutate` call with the saved revision.
7. On success call the same private load operation, keep the provider selected, clear the diff, and publish `phase: 'success'` with a completion message.
8. On failure restore `phase: 'error'` while retaining `diff` and `selection`; if error code/message indicates a revision conflict, tell the user to reload and discover again.

- [ ] **Step 9: Run controller tests and full typecheck**

```bash
pnpm test -- tests/controller.test.ts
pnpm typecheck
```

Expected: PASS.

- [ ] **Step 10: Commit the controller**

```bash
git add dsh-model-sync/src/client/types.ts dsh-model-sync/src/client/controller.ts dsh-model-sync/tests/controller.test.ts
git commit -m "feat: add model sync wire controller"
```

---

### Task 4: Register the Conversation Tab and Build the React View

**Files:**
- Create: `dsh-model-sync/src/client/register.ts`
- Create: `dsh-model-sync/src/client/react.ts`
- Create: `dsh-model-sync/src/client/ModelSyncView.ts`
- Create: `dsh-model-sync/src/client/index.ts`
- Create: `dsh-model-sync/src/client/styles.css`
- Create: `dsh-model-sync/src/client/globals.d.ts`
- Create: `dsh-model-sync/tests/register.test.ts`

**Interfaces:**
- Consumes: `ModelSyncController` and `ModelSyncSnapshot` from Task 3.
- Produces: Client plugin `{ name: 'dsh-model-sync', inject: ['slots'], apply(ctx) }`.
- Registers exactly one entry `{ name: 'conversation.view', id: 'models-sync', order: 30, label: 'Modelos' }`.

**Do not put `connection` in `inject`.** Both shipped clients that were read for this plan — `dsh-context` and `@deepseek-ai/dsh-client-ui-settings-models` — obtain it with `ctx.get("connection")` and never inject it. If `connection` is not an injectable service name, declaring it leaves the row stuck in PENDING and the tab silently never appears. Read it with `ctx.get('connection')` and handle `undefined` by registering nothing.

- [ ] **Step 1: Write the failing additive slot-registration test**

Create `tests/register.test.ts`:

```ts
import { expect, test, vi } from 'vitest'
import { registerModelSyncView } from '../src/client/register.ts'

test('registers an additive Models conversation view and returns the slot disposer', () => {
  const dispose = vi.fn()
  const register = vi.fn(() => dispose)
  const inject = vi.fn((_name, callback) => callback())
  const component = () => null

  const result = registerModelSyncView({ inject, register }, component)

  expect(inject).toHaveBeenCalledWith('conversation.view', expect.any(Function))
  expect(register).toHaveBeenCalledWith(
    { name: 'conversation.view', id: 'models-sync', order: 30, label: 'Modelos' },
    component,
  )
  expect(result).toBe(dispose)
})
```

- [ ] **Step 2: Run the registration test and verify RED**

Run `pnpm test -- tests/register.test.ts`.

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement the registration seam**

Create `register.ts` with narrow local interfaces and no browser/React import:

```ts
export function registerModelSyncView(
  slots: {
    inject(name: string, callback: () => () => void): () => void
    register(options: Record<string, unknown>, component: (props: unknown) => unknown): () => void
  },
  component: (props: unknown) => unknown,
): () => void {
  return slots.inject('conversation.view', () => slots.register(
    { name: 'conversation.view', id: 'models-sync', order: 30, label: 'Modelos' },
    component,
  ))
}
```

- [ ] **Step 4: Run the registration test and verify GREEN**

Run `pnpm test -- tests/register.test.ts`.

Expected: PASS.

- [ ] **Step 5: Create the React bridge and global declarations**

`react.ts`:

```ts
import type * as ReactNS from 'react'
export const React = require('react') as typeof ReactNS
export const h = React.createElement
```

`globals.d.ts`:

```ts
declare function require(id: string): unknown
declare let module: { exports: Record<string, unknown> }
declare let exports: Record<string, unknown>
declare module '*.css'
```

- [ ] **Step 6: Implement the view component against controller state**

`ModelSyncView.ts` must:

- Construct no controller itself; receive `{ controller }` from slot injection.
- Subscribe with `React.useSyncExternalStore(controller.subscribe, controller.snapshot, controller.snapshot)`. This relies on both Task 3 guarantees: arrow-property binding and a referentially stable snapshot.
- Call `controller.load()` once in `useEffect` with an empty dependency array, discarding the promise with `void`, and dispose only local effects.
- Render a "sin cambios" confirmation when a successful apply reported no differences.
- Render:
  - title and short source-of-truth explanation;
  - provider `<select>`;
  - **Buscar modelos** button;
  - counts for new/existing/missing;
  - a row per new model with an “Agregar” checkbox;
  - a read-only row per existing model;
  - a row per missing model with an “Eliminar” checkbox;
  - a warning naming every protected model and why it is protected, plus a distinct warning when a protection source could not be read;
  - **Aplicar sincronización** button only when a diff exists;
  - loading, empty, error, conflict and success messages using `role="status"` or `role="alert"`.

Use only `React.createElement`; do not use JSX. Button handlers must call controller methods and deliberately discard promises with `void`.

- [ ] **Step 7: Add scoped theme-aware CSS**

Create `.dms-*` styles using:

```css
.dms-root { height: 100%; overflow: auto; padding: 20px; color: var(--dsw-alias-label-primary); }
.dms-card { border: 1px solid var(--dsw-alias-border-l1); background: var(--dsw-alias-bg-layer-1); border-radius: 12px; padding: 16px; }
.dms-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 12px; align-items: center; }
.dms-muted { color: var(--dsw-alias-label-secondary); }
.dms-danger { color: var(--dsw-alias-red-primary, #d14343); }
```

Add responsive stacking below 640px and visible `:focus-visible` outlines. No global element selectors.

- [ ] **Step 8: Implement the Client Cordis entry**

`src/client/index.ts` must:

1. Import the stylesheet for build-time injection.
2. Read `connection` with `ctx.get('connection')` and return immediately when it is `undefined`, registering nothing.
3. Create one `ModelSyncController(connection.api)` in `apply`.
4. Create a small component closure that renders `ModelSyncView` with the controller.
5. Register it through `registerModelSyncView` using `ctx.slots`, which `inject` guarantees is ready.
6. Export:

```ts
export const name = 'dsh-model-sync'
export const inject = ['slots']
export function apply(ctx: unknown): void { /* narrow cast, ctx.get('connection'), registration */ }
```

No document/window access belongs in source; the tsdown wrapper alone references `window.__ModuleLoader__`.

- [ ] **Step 9: Run client-focused tests and typecheck**

```bash
pnpm test -- tests/register.test.ts tests/controller.test.ts
pnpm typecheck
```

Expected: PASS.

- [ ] **Step 10: Build and inspect the Client bundle wrapper**

Run:

```bash
pnpm build
head -5 lib/client.js
grep -n "conversation.view\|models-sync" lib/client.js | head
```

Expected:

- `lib/client.js` begins with `window.__ModuleLoader__.load({ id: "dsh-model-sync"`.
- The bundle contains `conversation.view` and `models-sync`.
- `lib/index.js` and `lib/index.d.ts` exist.

- [ ] **Step 11: Commit the Client tab**

```bash
git add dsh-model-sync/src/client dsh-model-sync/tests/register.test.ts dsh-model-sync/lib
git commit -m "feat: add Models conversation tab"
```

---

### Task 5: Add Manifest Verification and User Documentation

**Files:**
- Create: `dsh-model-sync/tests/manifest.test.ts`
- Create: `dsh-model-sync/README.md`
- Create: `dsh-model-sync/LICENSE`
- Modify: `dsh-model-sync/package.json` only if pack verification exposes missing files.

**Interfaces:**
- Consumes: package/bundle outputs from Tasks 1–4.
- Produces: a packable npm artifact with explicit DSH bundle and Client declarations.

- [ ] **Step 1: Write failing manifest tests**

Create `tests/manifest.test.ts` that reads `package.json` and `cordis.patch.yml` as text and asserts:

```ts
import { existsSync } from 'node:fs'

test('declares one installable bundle and web client', () => {
  expect(pkg.dsh.bundle.patch).toBe('./cordis.patch.yml')
  expect(pkg.dsh.client.platform).toBe('web')
  expect(pkg.exports['./client']).toBe('./lib/client.js')
  expect(patch.match(/id: dsh-model-sync/g)).toHaveLength(1)
  expect(patch.match(/name: dsh-model-sync/g)).toHaveLength(1)
  expect(pkg.files).toEqual(expect.arrayContaining(['lib', 'cordis.patch.yml', 'README.md', 'LICENSE']))
})

test('ships every file the manifest promises', () => {
  // `files` is only an allowlist; it does not prove the file exists on disk.
  // Without these stats the RED state below cannot happen.
  for (const name of ['README.md', 'LICENSE']) {
    expect(existsSync(new URL(`../${name}`, import.meta.url))).toBe(true)
  }
})
```

- [ ] **Step 2: Run the manifest test and verify RED**

Expected: the first test PASSES (Task 1 already wrote those manifest fields), and `ships every file the manifest promises` FAILS on the missing `README.md`. That second test is the real RED for this task — the manifest assertions are a regression pin, not the driver.

- [ ] **Step 3: Add README and Apache-2.0 license**

README sections:

1. Purpose and screenshot-free UI description.
2. Safety semantics: preview, non-empty discovery, default model guard, revision guard.
3. Install:

```bash
dsh plugin --profile web add ./dsh-model-sync-0.1.0.tgz
```

4. Remove:

```bash
dsh plugin --profile web remove dsh-model-sync
```

5. Development:

```bash
pnpm install --ignore-scripts
pnpm verify
pnpm pack
```

6. Supported first release: configurable providers exposing model discovery, primarily `llm-pi-ai` OpenAI-compatible `/models` endpoints.
7. Limitations: manual sync only; no automatic schedule; no advanced metadata editor.

Copy the full Apache-2.0 license into `LICENSE`.

- [ ] **Step 4: Run manifest and full package verification**

```bash
pnpm test
pnpm typecheck
pnpm build
pnpm pack --dry-run --json
```

Expected: all commands exit 0; the dry-run file list contains built Host/Client output, patch, README and LICENSE, and no source-only secrets or workspace files.

- [ ] **Step 5: Validate bundle configuration and source claims**

Run:

```text
verify config /opt/dsh-manage/dsh-model-sync/cordis.patch.yml
verify claim "dsh-model-sync registers the models-sync entry in conversation.view" scope /opt/dsh-manage/dsh-model-sync
verify claim "dsh-model-sync writes only the selected provider models path through settings.mutate" scope /opt/dsh-manage/dsh-model-sync
```

Expected: valid config and verified/line-cited claims. Unsupported claims must be investigated before proceeding.

- [ ] **Step 6: Commit documentation and packaging checks**

```bash
git add dsh-model-sync
git commit -m "docs: document model sync bundle"
```

---

### Task 6: Security Scan, Pack, and Isolated DSH Smoke Test

**Files:**
- Generated: `dsh-model-sync/dsh-model-sync-0.1.0.tgz`
- No real profile files modified in this task.

**Interfaces:**
- Consumes: verified package from Task 5.
- Produces: security verdict, tarball, and isolated installation/smoke evidence.

- [ ] **Step 1: Run the mandatory plugin source safety gate**

Run:

```text
gate_scan target=/opt/dsh-manage/dsh-model-sync
```

Expected: PASS, or WARN with every hit manually reviewed. BLOCK stops the installation workflow; do not bypass it.

- [ ] **Step 2: Build and create the tarball**

Run:

```bash
cd /opt/dsh-manage/dsh-model-sync
pnpm verify
pnpm pack
```

Expected: exit code 0 and `dsh-model-sync-0.1.0.tgz`.

- [ ] **Step 3: Scan the exact packed artifact when supported**

Run `gate_scan` against the extracted local package directory if the scanner cannot inspect `.tgz` directly. Do not execute install scripts during extraction. Expected: no new findings versus source.

- [ ] **Step 4: Run isolated install-and-boot test drive**

Run:

```text
test_drive target=/opt/dsh-manage/dsh-model-sync/dsh-model-sync-0.1.0.tgz headlessTask="Reply with the single word: ok"
```

A real task string is required. Passing `headlessTask=""` skips the boot smoke stage entirely, which would make the boot expectation below vacuous rather than verified.

Expected:

- install passes;
- `--dump-config` includes one `dsh-model-sync` row;
- headless boot runs and reports no failed-to-load marker;
- removal and quarantined cleanup pass.

If the smoke stage is skipped for lack of an API key, record that explicitly as "smoke skipped, not passed" and do not count it as boot evidence.

- [ ] **Step 5: Inspect package contents and final git status**

```bash
pnpm pack --dry-run --json
git status --short
git log --oneline -6
```

Expected: only the intended plugin files/tarball state is present; all implementation commits are visible.

- [ ] **Step 6: Stop before real-profile installation and request approval**

Report:

- test counts;
- build result;
- gate verdict;
- test-drive result;
- exact tarball path;
- expected change: install package into profile `web`, then refresh existing `http://127.0.0.1:3080` after restart/rebuild as required.

Ask for explicit approval before running:

```bash
dsh plugin --profile web add /opt/dsh-manage/dsh-model-sync/dsh-model-sync-0.1.0.tgz
```

Do not run this real-profile command inside Task 6.

---

## Final Verification Checklist

- [ ] `pnpm test` passes all normalization, policy, controller, registration and manifest tests.
- [ ] `pnpm typecheck` exits 0 for both the Node and the client configuration (needs `allowImportingTsExtensions` in both, and `"types": []` on the client).
- [ ] A removal is refused when it would drop the Host default, the current session's model, or anything while a protection source is unreadable.
- [ ] `snapshot()` is referentially stable between transitions, and `snapshot`/`subscribe` work as detached references.
- [ ] Changing provider clears any diff discovered against the previous provider.
- [ ] `modelsMutation` refuses an empty settings path, and providers with one are filtered out at load.
- [ ] An unchanged catalog reports success without sending a mutation.
- [ ] The client entry reads `connection` through `ctx.get` and does not inject it.
- [ ] `pnpm build` emits `lib/index.js`, `lib/index.d.ts`, and wrapped `lib/client.js`.
- [ ] `verify config` accepts `cordis.patch.yml`.
- [ ] Source claims about slot registration and path-limited mutation are verified with line evidence.
- [ ] Security gate is not BLOCK.
- [ ] Isolated `test_drive` installs, composes, boots, removes and cleans successfully.
- [ ] Real profile remains unchanged until the user approves installation.
