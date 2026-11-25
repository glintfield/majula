import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import tls from 'node:tls';
import { fileURLToPath } from 'node:url';
import { Code, ConnectError, createClient, type Interceptor } from '@connectrpc/connect';
import { createConnectTransport } from '@connectrpc/connect-node';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Event, SpikeService } from '../gen/ts/spike/v1/spike_pb.js';
import { type SpikeServer, startSpikeServer } from '../server/server.js';

const scripts = fileURLToPath(new URL('../scripts/', import.meta.url));
const token = 'test-token';
const watchIntervalMs = 50;

let certDir: string;
let ca: Buffer;
let server: SpikeServer;

beforeAll(async () => {
  certDir = mkdtempSync(join(tmpdir(), 'majula-spike-'));
  execFileSync('sh', [join(scripts, 'init-ca.sh'), certDir]);
  ca = readFileSync(join(certDir, 'ca.crt'));
  server = await startSpikeServer({
    certDir,
    host: '127.0.0.1',
    port: 0,
    token,
    watchIntervalMs,
    logCapacity: 1000,
  });
});

afterAll(async () => {
  await server.close();
  rmSync(certDir, { recursive: true, force: true });
});

function clientWith(bearer?: string) {
  const interceptors: Interceptor[] = bearer
    ? [
        (next) => (req) => {
          req.header.set('authorization', `Bearer ${bearer}`);
          return next(req);
        },
      ]
    : [];
  return createClient(
    SpikeService,
    createConnectTransport({
      httpVersion: '2',
      baseUrl: `https://localhost:${String(server.port)}`,
      nodeOptions: { ca },
      interceptors,
    }),
  );
}

async function take(stream: AsyncIterable<Event>, n: number): Promise<bigint[]> {
  const seqs: bigint[] = [];
  for await (const event of stream) {
    seqs.push(event.seq);
    if (seqs.length === n) break;
  }
  return seqs;
}

function consecutiveFrom(first: bigint, n: number): bigint[] {
  return Array.from({ length: n }, (_, i) => first + BigInt(i));
}

function leafFingerprint(): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = tls.connect(
      { host: '127.0.0.1', port: server.port, servername: 'localhost', ca, ALPNProtocols: ['h2'] },
      () => {
        resolve(socket.getPeerCertificate().fingerprint256);
        socket.end();
      },
    );
    socket.once('error', reject);
  });
}

describe('spike server', () => {
  it('answers a unary call', async () => {
    const res = await clientWith(token).echo({ message: 'hi' });
    expect(res.message).toBe('hi');
  });

  it.each([undefined, 'wrong'])('rejects bearer %s as unauthenticated', async (bearer) => {
    const client = clientWith(bearer);
    await expect(client.echo({ message: 'hi' })).rejects.toSatisfy(
      (err) => ConnectError.from(err).code === Code.Unauthenticated,
    );
    await expect(take(client.watch({}), 1)).rejects.toSatisfy(
      (err) => ConnectError.from(err).code === Code.Unauthenticated,
    );
  });

  it('streams consecutive events', { timeout: 10_000 }, async () => {
    const seqs = await take(clientWith(token).watch({}), 5);
    expect(seqs).toEqual(consecutiveFrom(seqs[0] ?? 0n, 5));
  });

  it('resumes from after_seq without gaps', { timeout: 10_000 }, async () => {
    const client = clientWith(token);
    const first = await take(client.watch({}), 3);
    const last = first.at(-1) ?? 0n;
    // let the log move past last+3 so the resumed events can only come from replay
    await setTimeout(5 * watchIntervalMs);
    const resumed = await take(client.watch({ afterSeq: last }), 3);
    expect(resumed).toEqual(consecutiveFrom(last + 1n, 3));
  });

  it('serves a rotated leaf signed by the same CA', async () => {
    const before = await leafFingerprint();
    execFileSync('sh', [join(scripts, 'rotate-leaf.sh'), certDir]);
    server.reloadCerts();
    expect(await leafFingerprint()).not.toBe(before);

    const res = await clientWith(token).echo({ message: 'after rotation' });
    expect(res.message).toBe('after rotation');
  });
});
