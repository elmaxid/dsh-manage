import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { readFileSync } from 'node:fs'
import { defineConfig } from 'tsdown'

const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8'))

// Mirrors packages/client/web/src/platform.ts in deepseek-harness: the shell
// seeds these specifiers into the frozen browser module table, so the client
// bundle leaves them to the injected `require` instead of inlining them.
const CLIENT_EXTERNALS = [
  'react',
  '@deepseek-ai/cordis',
  '@deepseek-ai/dsh-client-runtime/client',
]

// Inlines an imported stylesheet verbatim into a `document.head` style tag.
// No CSS toolchain: the stylesheet is small and hand-written, minification is
// not worth a build dependency. The virtual id must NOT end with `.css` —
// tsdown's own css-pipeline guard matches on that suffix.
const CSS_VIRTUAL_PREFIX = '\0dms-css:'
const CSS_VIRTUAL_SUFFIX = '.mjs'

function cssInlinePlugin(pluginId) {
  return {
    name: 'dms-css-inline',
    resolveId(source, importer) {
      if (!source.endsWith('.css')) return null
      const abs = importer ? resolve(dirname(importer), source) : resolve(source)
      return CSS_VIRTUAL_PREFIX + abs + CSS_VIRTUAL_SUFFIX
    },
    async load(virtualId) {
      if (!virtualId.startsWith(CSS_VIRTUAL_PREFIX)) return null
      const fileId = virtualId.slice(CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length)
      this.addWatchFile(fileId)
      const css = await readFile(fileId, 'utf8')
      const tagId = `${pluginId}/${fileId.split('/').pop()}`
      return [
        `const css = ${JSON.stringify(css)};`,
        `const tagId = ${JSON.stringify(tagId)};`,
        `if (typeof document !== 'undefined' && document.querySelector('style[data-plugin-css=' + JSON.stringify(tagId) + ']') === null) {`,
        `  const tag = document.createElement('style');`,
        `  tag.dataset.plugin = ${JSON.stringify(pluginId)};`,
        `  tag.dataset.pluginCss = tagId;`,
        `  tag.textContent = css;`,
        `  document.head.appendChild(tag);`,
        `}`,
        `export default css;`,
      ].join('\n')
    },
  }
}

export default defineConfig([
  {
    // Host half: ESM for Node 22 with shipped type declarations.
    name: pkg.name,
    entry: { index: 'src/index.ts' },
    outDir: 'lib',
    format: ['esm'],
    platform: 'node',
    target: 'node22',
    dts: true,
    clean: true,
    deps: { neverBundle: (specifier) => CLIENT_EXTERNALS.includes(specifier) },
  },
  {
    // Client half: browser closure bundle with the module-loader handoff.
    name: `${pkg.name}/client`,
    entry: { client: 'src/client/index.ts' },
    outDir: 'lib',
    format: 'cjs',
    platform: 'browser',
    // dts would wrap the banner/footer into a .d.cts and break parsing.
    dts: false,
    sourcemap: true,
    clean: false,
    deps: { neverBundle: (specifier) => CLIENT_EXTERNALS.includes(specifier) },
    plugins: [cssInlinePlugin(pkg.name)],
    outputOptions: {
      entryFileNames: 'client.js',
      // The closure-factory handoff every `dsh.client` package's ./client
      // export must use; mirrors the verified dsh-context banner/intro/footer.
      banner: `window.__ModuleLoader__.load({ id: ${JSON.stringify(pkg.name)}, factory: (require) => {`,
      intro: 'var module = { exports: {} }; var exports = module.exports;',
      footer: 'return module.exports; } });',
    },
  },
])