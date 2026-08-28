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
    const key = typeof sessionId === 'string' && sessionId !== '' ? sessionId : ''
    return h(ModelSyncView, { controller: controllerFor(key) })
  }

  registerModelSyncView(context.slots, component)
}
