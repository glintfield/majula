import js from '@eslint/js';
import { defineConfig } from 'eslint/config';
import globals from 'globals';
import tseslint from 'typescript-eslint';

const BOUNDARY = 'ADR 0012: this directory may not import this module';
const restrict = (regex) => ({ regex, message: BOUNDARY });
const FS = restrict('^(node:)?fs(/promises)?$');
const PROCESSES = restrict('^(node:)?(child_process|cluster|worker_threads)$');
const SQLITE = restrict('^node:sqlite$');
const RUNTIMES = restrict('^@anthropic-ai/claude-agent-sdk(/|$)');
const LOADER = restrict('^(node:)?module$');
const HOST = restrict('^\\.{1,2}/(.*/)?host(/|$)');
const LOCAL_NODE = restrict('^\\.{1,2}/(.*/)?local-node(/|$)');
const STORAGE = restrict('^\\.{1,2}/(.*/)?storage(/|$)');
const PROCESS_BYPASSES = ['getBuiltinModule', 'binding', 'dlopen'];
const PROCESS_MODULE = ['process', 'node:process'].map((name) => ({
  name,
  importNames: PROCESS_BYPASSES,
  message: BOUNDARY,
}));
const boundary = (...patterns) => ['error', { paths: PROCESS_MODULE, patterns }];

export default defineConfig(
  { ignores: ['**/dist/**', '**/coverage/**', 'spike/**'] },
  js.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  {
    languageOptions: {
      globals: globals.node,
      parserOptions: {
        projectService: { allowDefaultProject: ['vitest.config.ts'] },
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
  { files: ['**/*.js', '**/*.mjs'], ...tseslint.configs.disableTypeChecked },
  {
    files: ['server/src/**/*.{ts,mts}'],
    rules: {
      'no-restricted-imports': boundary(FS, PROCESSES, SQLITE, RUNTIMES, LOADER, HOST, LOCAL_NODE),
      'no-restricted-syntax': ['error', { selector: 'ImportExpression', message: BOUNDARY }],
      'no-restricted-properties': [
        'error',
        ...PROCESS_BYPASSES.map((property) => ({ object: 'process', property, message: BOUNDARY })),
      ],
    },
  },
  {
    files: ['server/src/storage/**/*.{ts,mts}'],
    rules: { 'no-restricted-imports': boundary(PROCESSES, RUNTIMES, LOADER, HOST, LOCAL_NODE) },
  },
  {
    files: ['server/src/host/**/*.{ts,mts}'],
    rules: { 'no-restricted-imports': boundary(SQLITE, RUNTIMES, LOADER) },
  },
  {
    files: ['server/src/local-node/**/*.{ts,mts}'],
    rules: {
      'no-restricted-imports': ['error', { patterns: [SQLITE, HOST, STORAGE] }],
      'no-restricted-syntax': 'off',
      'no-restricted-properties': 'off',
    },
  },
  {
    files: ['server/src/**/*.{cts,tsx}'],
    rules: {
      'no-restricted-syntax': [
        'error',
        { selector: 'Program', message: 'ADR 0012: server/src is .ts and .mts only' },
      ],
    },
  },
);
