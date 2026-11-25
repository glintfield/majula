import { readFileSync } from 'node:fs';
import http2 from 'node:http2';
import type { AddressInfo } from 'node:net';
import { join } from 'node:path';
import { Code, ConnectError, type Interceptor } from '@connectrpc/connect';
import { connectNodeAdapter } from '@connectrpc/connect-node';
import { SpikeService } from '../gen/ts/spike/v1/spike_pb.js';
import { EventLog, spikeService } from './service.js';

export interface SpikeServerOptions {
  certDir: string;
  host: string;
  port: number;
  token: string;
  watchIntervalMs: number;
  logCapacity: number;
}

export interface SpikeServer {
  port: number;
  reloadCerts(): void;
  close(): Promise<void>;
}

/** startSpikeServer serves SpikeService over HTTP/2 TLS with the leaf in certDir; port 0 picks a free one. */
export async function startSpikeServer(opts: SpikeServerOptions): Promise<SpikeServer> {
  const log = new EventLog(opts.watchIntervalMs, opts.logCapacity);
  const requireBearer: Interceptor = (next) => (req) => {
    if (req.header.get('authorization') !== `Bearer ${opts.token}`) {
      throw new ConnectError('missing or invalid bearer token', Code.Unauthenticated);
    }
    return next(req);
  };
  const server = http2.createSecureServer(
    { ...readLeaf(opts.certDir), allowHTTP1: true },
    connectNodeAdapter({
      routes: (router) => router.service(SpikeService, spikeService(log)),
      interceptors: [requireBearer],
    }),
  );

  const sessions = new Set<http2.ServerHttp2Session>();
  server.on('session', (session) => {
    sessions.add(session);
    session.on('close', () => sessions.delete(session));
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(opts.port, opts.host, resolve);
  });

  return {
    port: (server.address() as AddressInfo).port,
    reloadCerts() {
      server.setSecureContext(readLeaf(opts.certDir));
    },
    async close() {
      log.close();
      // server.close waits for every open session, and clients keep idle HTTP/2 sessions alive
      for (const session of sessions) session.destroy();
      await new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      });
    },
  };
}

function readLeaf(certDir: string): { key: Buffer; cert: Buffer } {
  const read = (name: string) => {
    const path = join(certDir, name);
    try {
      return readFileSync(path);
    } catch (err) {
      throw new Error(`reading ${path}: run npm run certs:init`, { cause: err });
    }
  };
  return { key: read('leaf.key'), cert: read('leaf.crt') };
}
