/**
 * Additive `conversation.view` registration seam.
 *
 * Deliberately framework-free: no browser globals, no React import, so the
 * registration contract stays unit-testable under plain Node (vitest). The
 * `slots` face is the narrow structural slice of the Cordis client
 * SlotRegistry that this plugin needs:
 *
 * - `inject(key, callback)` runs `callback` once the slot declaration is on
 *   the ledger and returns an idempotent disposer that also cancels a pending
 *   wait (the declaration may not exist yet at apply time).
 * - `register(options, component)` adds one entry and returns the disposer
 *   that unregisters it.
 *
 * The disposer returned by `inject` is therefore the single owner of every
 * side effect this plugin causes in the slot tree: invoking it unregisters
 * the Models entry (and, while still pending, cancels the wait).
 *
 * Exactly one additive entry is registered; shipped `conversation.view` ids
 * (`chat` and friends) are never replaced.
 */
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
