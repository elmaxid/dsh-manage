/**
 * Host half of the bundle.
 *
 * It is deliberately inert: everything this plugin does happens in the browser
 * half, which reaches the harness over the existing `connection` wire. The row
 * exists because `cordis.patch.yml` needs a host entry to mount, and the
 * manifest's `main` must resolve to a real built file.
 *
 * The diff engine in `./sync.ts` is intentionally NOT re-exported here. The
 * client imports it directly (the bundler inlines it), so re-exporting only
 * published a dozen internal symbols as plugin API that nothing consumes and
 * that would then have to be kept stable.
 */
export const name = 'dsh-model-sync'
export function apply(): void {}
