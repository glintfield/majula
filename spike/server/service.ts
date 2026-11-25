import { EventEmitter, once } from 'node:events';
import { create } from '@bufbuild/protobuf';
import { Code, ConnectError, type ServiceImpl } from '@connectrpc/connect';
import { type Event, EventSchema, SpikeService } from '../gen/ts/spike/v1/spike_pb.js';

/** EventLog appends a sequenced event on a fixed interval and keeps the most recent `capacity`. */
export class EventLog {
  private events: Event[] = [];
  private nextSeq = 1n;
  private readonly appended = new EventEmitter();
  private readonly timer: NodeJS.Timeout;

  constructor(
    intervalMs: number,
    private readonly capacity: number,
  ) {
    this.appended.setMaxListeners(0);
    this.timer = setInterval(() => {
      this.append();
    }, intervalMs);
  }

  get latestSeq(): bigint {
    return this.nextSeq - 1n;
  }

  get oldestSeq(): bigint {
    return this.events[0]?.seq ?? this.nextSeq;
  }

  since(afterSeq: bigint): Event[] {
    return this.events.filter((e) => e.seq > afterSeq);
  }

  async nextAppend(signal: AbortSignal): Promise<void> {
    await once(this.appended, 'append', { signal });
  }

  close(): void {
    clearInterval(this.timer);
  }

  private append(): void {
    const seq = this.nextSeq++;
    this.events.push(create(EventSchema, { seq, payload: `event ${seq.toString()}` }));
    if (this.events.length > this.capacity) this.events.shift();
    this.appended.emit('append');
  }
}

/** spikeService serves Echo and a resumable Watch over the shared log. */
export function spikeService(log: EventLog): ServiceImpl<typeof SpikeService> {
  return {
    echo(req) {
      return { message: req.message };
    },
    async *watch(req, ctx) {
      let cursor = req.afterSeq ?? log.latestSeq;
      if (cursor > log.latestSeq) {
        throw new ConnectError(
          `after_seq ${cursor.toString()} is ahead of latest ${log.latestSeq.toString()}`,
          Code.OutOfRange,
        );
      }
      while (!ctx.signal.aborted) {
        if (cursor + 1n < log.oldestSeq) {
          throw new ConnectError(
            `events after ${cursor.toString()} are no longer buffered (oldest ${log.oldestSeq.toString()})`,
            Code.FailedPrecondition,
          );
        }
        for (const event of log.since(cursor)) {
          yield event;
          cursor = event.seq;
        }
        try {
          await log.nextAppend(ctx.signal);
        } catch {
          return;
        }
      }
    },
  };
}
