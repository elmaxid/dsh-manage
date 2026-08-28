/**
 * Messages shared between the controller (which publishes them) and the view
 * (which branches on them).
 *
 * The view renders a distinct "sin cambios" confirmation, which it can only
 * recognise by matching the message the controller published. Keeping a second
 * copy as a literal in the view made that branch silently unreachable the
 * moment either side was reworded, with no test to catch it.
 */
export const NO_CHANGES_MESSAGE = 'No hay cambios que aplicar.'
