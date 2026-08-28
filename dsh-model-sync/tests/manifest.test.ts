import { existsSync, readFileSync } from 'node:fs'
import { expect, test } from 'vitest'

const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
const patch = readFileSync(new URL('../cordis.patch.yml', import.meta.url), 'utf8')

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

test('every declared entry point resolves to a built file', () => {
  // This is the check that was missing while the build emitted `index.mjs`
  // against a manifest promising `index.js`: `files` listed `lib`, every other
  // assertion passed, and the host row still resolved to a nonexistent file.
  // Derive the paths from the manifest so renaming an entry cannot escape it.
  const entries = [
    pkg.main,
    pkg.types,
    pkg.exports['.'].default,
    pkg.exports['.'].types,
    pkg.exports['./client'],
  ]
  for (const entry of entries) {
    expect(entry, 'manifest entry must be declared').toBeTypeOf('string')
    const missing = !existsSync(new URL(`../${entry.replace(/^\.\//, '')}`, import.meta.url))
    expect(missing, `${entry} is declared in package.json but was not built`).toBe(false)
  }
})
