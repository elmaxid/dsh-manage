import { expect, test, vi } from 'vitest'
import { registerModelSyncView } from '../src/client/register.ts'

test('registers an additive Models conversation view and returns the slot disposer', () => {
  const dispose = vi.fn()
  const register = vi.fn(() => dispose)
  const inject = vi.fn((_name, callback) => callback())
  const component = () => null

  const result = registerModelSyncView({ inject, register }, component)

  expect(inject).toHaveBeenCalledTimes(1)
  expect(inject).toHaveBeenCalledWith('conversation.view', expect.any(Function))
  expect(register).toHaveBeenCalledTimes(1)
  expect(register).toHaveBeenCalledWith(
    { name: 'conversation.view', id: 'models-sync', order: 30, label: 'Modelos' },
    component,
  )
  expect(result).toBe(dispose)
})

test('the returned disposer tears the slot registration down exactly once', () => {
  const dispose = vi.fn()
  const register = vi.fn(() => dispose)
  const inject = vi.fn((_name, callback) => callback())

  const result = registerModelSyncView({ inject, register }, () => null)
  expect(dispose).not.toHaveBeenCalled()

  result()

  expect(dispose).toHaveBeenCalledTimes(1)
})
