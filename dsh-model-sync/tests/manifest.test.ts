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
