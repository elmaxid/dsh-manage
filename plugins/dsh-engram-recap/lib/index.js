/**
 * dsh-engram-recap host half (plain ESM, ASCII only).
 *
 * Mounts once at the host composition level (like dsh-startup-guard) and
 * contributes a dynamic system-prompt context — re-evaluated on every model
 * request, not just once at session start — that nudges every agent to:
 *
 *   1. call Engram's mcp__engram__mem_context / mem_search near the start of
 *      a session, before its first substantive action;
 *   2. call mcp__engram__mem_save (or mem_session_summary) roughly every
 *      `remindEvery` turns, IF the recent exchanges produced anything worth
 *      remembering (a decision, bugfix, discovery, or lesson).
 *
 * This exists because tool descriptions alone ("call this proactively") are
 * advisory text the model can silently skip; the nudge is re-injected by the
 * runtime itself on a schedule, independent of the model remembering to ask
 * for it. It never calls Engram tools itself (this Host plugin sandbox has
 * no AbortController/crypto to drive a tool-execute call safely) — it only
 * steers the model to call them, same mechanism dsh-plan-mode uses for its
 * policy section.
 *
 * Per-session turn counts live in an in-memory WeakMap keyed by Session, so
 * they are process-local and reset on restart — same lifetime tradeoff as
 * every other stateless per-request Cordis contribution in this stack.
 *
 * @module dsh-engram-recap
 */

const DEFAULT_REMIND_EVERY = 6;

export const name = 'dsh-engram-recap';
export const inject = ['systemPrompt'];

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {{ remindEvery?: number }} [config]
 */
export function apply(ctx, config = {}) {
  const remindEvery = Number.isFinite(config.remindEvery) && config.remindEvery > 0
    ? Math.floor(config.remindEvery)
    : DEFAULT_REMIND_EVERY;

  /** @type {WeakMap<object, number>} */
  const turnCounts = new WeakMap();

  ctx.on('agent/turn-stopping', ({ agent }) => {
    const session = agent.session;
    const count = (turnCounts.get(session) || 0) + 1;
    turnCounts.set(session, count);
  });

  ctx.systemPrompt.context({
    name: 'engram-recap-reminder',
    order: 5,
    text(context) {
      const agent = context.agent;
      if (agent === undefined) return '';
      const session = agent.session;
      const count = turnCounts.get(session) || 0;

      if (count === 0) {
        return (
          '<system-reminder>\n' +
          'Before your first substantive action this session, call mcp__engram__mem_context ' +
          '(and mcp__engram__mem_search for anything specific) to recall relevant prior ' +
          'decisions, bugfixes, and learnings for this project. Do this now if you have not ' +
          'already in this conversation.\n' +
          '</system-reminder>'
        );
      }

      if (count % remindEvery === 0) {
        return (
          '<system-reminder>\n' +
          'Memory checkpoint: if the last few exchanges produced a decision, bugfix, ' +
          'discovery, or lesson learned, save it now with mcp__engram__mem_save using the ' +
          '**What**/**Why**/**Where**/**Learned** format — do not wait to be asked. If nothing ' +
          'memory-worthy happened, do nothing.\n' +
          '</system-reminder>'
        );
      }

      return '';
    },
  });
}
