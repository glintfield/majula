import path from 'node:path';
import { ESLint } from 'eslint';
import tseslint from 'typescript-eslint';
import { describe, expect, it } from 'vitest';

const BOUNDARY_RULES = new Set([
  'no-restricted-imports',
  'no-restricted-syntax',
  'no-restricted-properties',
]);

const eslint = new ESLint({
  cwd: path.resolve(import.meta.dirname, '..'),
  overrideConfig: [{ files: ['**/*.{ts,cts,tsx}'], ...tseslint.configs.disableTypeChecked }],
});

const CORE = 'server/src/jobs/x.ts';
const STORAGE = 'server/src/storage/db.ts';
const HOST = 'server/src/host/main.ts';
const LOCAL_NODE = 'server/src/local-node/git.ts';

describe('node boundary (ADR 0012)', () => {
  it.each([
    [CORE, "import 'node:fs';", true],
    [CORE, "import 'node:child_process';", true],
    [CORE, "import '../local-node/git.js';", true],
    [CORE, "import '../host/config.js';", true],
    [CORE, "await import('./y.js');", true],
    [CORE, "process.getBuiltinModule('fs');", true],
    [CORE, "import { getBuiltinModule } from 'node:process';", true],
    [CORE, "import '../node/index.js';", false],
    [CORE, "import '../storage/db.js';", false],
    ['server/src/jobs/x.cts', 'export {};', true],
    ['server/src/jobs/x.tsx', 'export {};', true],
    [STORAGE, "import 'node:fs';", false],
    [STORAGE, "import 'node:sqlite';", false],
    [STORAGE, "import 'node:child_process';", true],
    [STORAGE, "import '../local-node/x.js';", true],
    [HOST, "import 'node:child_process';", false],
    [HOST, "import '../local-node/index.js';", false],
    [HOST, "import '@anthropic-ai/claude-agent-sdk';", true],
    [LOCAL_NODE, "import 'node:child_process';", false],
    [LOCAL_NODE, "import '@anthropic-ai/claude-agent-sdk';", false],
    [LOCAL_NODE, "await import('./y.js');", false],
    [LOCAL_NODE, "import 'node:sqlite';", true],
    [LOCAL_NODE, "import '../storage/db.js';", true],
    [LOCAL_NODE, "import '../host/x.js';", true],
  ])('%s: %s blocked=%s', async (filePath, code, blocked) => {
    const [result] = await eslint.lintText(code, { filePath });
    expect(result.messages.filter((m) => m.fatal)).toEqual([]);
    expect(result.messages.some((m) => BOUNDARY_RULES.has(m.ruleId))).toBe(blocked);
  });
});
