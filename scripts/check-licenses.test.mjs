import { describe, expect, it } from 'vitest';
import { isAllowed } from './check-licenses.mjs';

describe('isAllowed', () => {
  it.each([
    ['MIT', true],
    ['(MIT OR GPL-3.0)', true],
    ['MIT AND GPL-3.0', false],
    ['(MIT OR GPL-3.0) AND GPL-2.0', false],
    ['GPL-3.0', false],
    ['UNKNOWN', false],
    ['Apache-2.0 WITH LLVM-exception', false],
  ])('%s → %s', (expr, expected) => {
    expect(isAllowed(expr)).toBe(expected);
  });
});
