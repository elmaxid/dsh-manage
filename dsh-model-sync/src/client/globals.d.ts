/**
 * Ambient declarations for the closure-bundle globals.
 *
 * `tsconfig.client.json` compiles with `"types": []` precisely so these
 * declarations do not collide with `@types/node` (which would otherwise own
 * `require`, `module` and `exports`). Do not enable `skipLibCheck` or add
 * node types to the client program.
 *
 * The tsdown Client wrapper evaluates this bundle as a CJS closure through
 * `window.__ModuleLoader__`, which provides the CommonJS trio; `*.css` is
 * inlined by the bundler at build time.
 */
declare function require(id: string): unknown
declare let module: { exports: Record<string, unknown> }
declare let exports: Record<string, unknown>
declare module '*.css'
