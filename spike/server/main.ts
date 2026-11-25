import { fileURLToPath } from 'node:url';
import { startSpikeServer } from './server.js';

const env = process.env;
const host = env.SPIKE_HOST ?? '127.0.0.1';

const server = await startSpikeServer({
  certDir: env.CERT_DIR ?? fileURLToPath(new URL('../certs', import.meta.url)),
  host,
  port: Number(env.SPIKE_PORT ?? 8443),
  token: env.SPIKE_TOKEN ?? 'spike-dev-token',
  watchIntervalMs: Number(env.SPIKE_WATCH_INTERVAL_MS ?? 1000),
  logCapacity: Number(env.SPIKE_LOG_CAPACITY ?? 3600),
});
console.log(`listening on https://${host}:${String(server.port)}`);

process.on('SIGHUP', () => {
  try {
    server.reloadCerts();
    console.log('reloaded leaf certificate');
  } catch (err) {
    console.error('reloading leaf certificate failed; still serving the old one', err);
  }
});
