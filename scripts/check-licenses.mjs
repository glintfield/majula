import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const ALLOWED = new Set([
  'MIT',
  'MIT-0',
  'ISC',
  'BSD-2-Clause',
  'BSD-3-Clause',
  '0BSD',
  'Apache-2.0',
  'Unlicense',
  'CC0-1.0',
  'BlueOak-1.0.0',
  'Python-2.0',
  'Zlib',
]);

const NO_PACKAGES = 'No licenses in packages found';

/** Reports whether an SPDX expression is satisfiable using only allowlisted licenses. */
export function isAllowed(expr) {
  const bare = expr.trim().replace(/^\((.*)\)$/, '$1');
  if (/[()]/.test(bare)) return false;
  return bare
    .split(' OR ')
    .some((alt) => alt.split(' AND ').every((part) => ALLOWED.has(part.trim())));
}

function main() {
  const output = execFileSync('pnpm', ['licenses', 'list', '--prod', '--json', '--recursive'], {
    encoding: 'utf8',
  }).trim();
  const byLicense = output === NO_PACKAGES ? {} : JSON.parse(output);

  let count = 0;
  const offenders = [];
  for (const [license, pkgs] of Object.entries(byLicense)) {
    count += pkgs.length;
    if (isAllowed(license)) continue;
    for (const pkg of pkgs) offenders.push(`${pkg.name}@${pkg.versions.join(',')} — ${license}`);
  }

  if (offenders.length > 0) {
    console.error('Production dependencies with licenses outside the allowlist:');
    for (const line of offenders) console.error(`  ${line}`);
    process.exit(1);
  }
  console.log(`${count} production packages, all licenses allowed`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) main();
