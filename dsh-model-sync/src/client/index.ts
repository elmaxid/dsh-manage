/**
 * Client Cordis entry for the Models sync tab.
 *
 * Plugin shape consumed by the DSH client runtime:
 * `{ name: 'dsh-model-sync', inject: ['slots'], apply(ctx) }`.
 *
 * Hard rules honored here:
 * - `connection` is NEVER declared in `inject` (it is not an injectable
 *   service name there; declaring it would leave the row stuck in PENDING).
 *   It is read with `ctx.get('connection')`; when absent, nothing is
 *   registered and the apply is a no-op.
 * - Registration happens through the `registerModelSyncView` seam and
 *   `ctx.slots`, which the `['slots']` inject guarantees is ready. The
 *   disposer returned by the slot injection owns the whole teardown.
 * - No `document`/`window` access belongs in this source; the tsdown
 *   wrapper alone references `window.__ModuleLoader__`.
 */
import './styles.css'
import { ModelSyncController } from './controller.ts'
import { ModelSyncView } from './ModelSyncView.ts'
import { h } from './react.ts'
import { registerModelSyncView } from './register.ts'
import type { ModelSyncApi } from './types.ts'

/** Structural face of the Cordis client context used by this plugin. */
interface ClientContext {
  get(service: string): unknown
  /** Present on a real Cordis fiber; guarded because the tests fake this shape. */
  effect?(callback: () => () => void): void
  slots: {
    inject(name: string, callback: () => () => void): () => void
    register(options: Record<string, unknown>, component: (props: unknown) => unknown): () => void
  }
}

/** Standard props a session-scoped `conversation.view` entry receives. */
interface ConversationViewProps {
  sessionId?: unknown
}

export const name = 'dsh-model-sync'
export const inject = ['slots']

export function apply(ctx: unknown): void {
  const context = ctx as ClientContext

  // Wire root absent (unexpected page composition): register nothing.
  const connection = context.get('connection') as { api: unknown } | undefined
  if (connection === undefined) return

  // The wire face this plugin consumes, narrowed to the controller's contract.
  const api = connection.api as unknown as ModelSyncApi

  // `conversation.view` is session-scoped: the slot supplies the `sessionId`
  // through its standard entry props, so one controller exists per rendered
  // session and the protection sources are always queried for the session the
  // tab is actually showing.
  const controllers = new Map<string, ModelSyncController>()

  const controllerFor = (sessionId: string): ModelSyncController => {
    let controller = controllers.get(sessionId)
    if (controller === undefined) {
      controller = new ModelSyncController(api, sessionId)
      controllers.set(sessionId, controller)
    }
    return controller
  }

  const component = (props: unknown) => {
    const sessionId = (props as ConversationViewProps | null | undefined)?.sessionId
    // Without a real session id the protection sources cannot be queried for
    // the session this tab is showing. Collapsing to a shared '' key would let
    // two unrelated views share one controller and would query
    // `sessions.models({ sessionId: '' })`. Refuse instead of degrading.
    if (typeof sessionId !== 'string' || sessionId === '') {
      return h('div', { className: 'dms-empty' }, 'No se pudo identificar la sesión; abre la pestaña desde una conversación.')
    }
    return h(ModelSyncView, { controller: controllerFor(sessionId) })
  }

  // The slot disposer is the single owner of this plugin's teardown, so it must
  // be retained rather than discarded: it also drops the per-session
  // controllers, which otherwise outlive every session the tab ever showed.
  const disposeSlot = registerModelSyncView(context.slots, component)
  context.effect?.(() => () => {
    disposeSlot()
    controllers.clear()
  })
}
