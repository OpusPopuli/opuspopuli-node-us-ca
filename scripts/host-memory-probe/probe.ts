/**
 * VENDORED from OpusPopuli/opuspopuli scripts/host-memory-probe/. Change it
 * there and copy it here, in both node repos.
 *
 * Host memory probe (opuspopuli#1434, `docs/plans/gpu-lane-host-memory-gate.md`).
 *
 * The workers that call Ollama run in Docker and cannot see the host's
 * memory, so this small process on the host reports it. The LLM provider's
 * host gate asks it before any call that would load a model. It answers only
 * with numbers, so there is no personal data in it, and it listens on loopback
 * only. Containers reach it at host.docker.internal, as they reach Ollama.
 *
 *   GET /memory -> { reclaimableBytes, swapUsedBytes, swapTotalBytes, at }
 *
 * macOS only (vm_stat, sysctl). Run with Node 22:
 *   node --experimental-strip-types scripts/host-memory-probe/probe.ts
 * Installed as a launchd agent by ./install.sh.
 */

import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);

export interface VmStat {
  pageSize: number;
  pages: Record<string, number>;
}

/**
 * `vm_stat` output: a page-size header, then `Pages free:   523273.` lines.
 * Keys are lower-cased and trimmed of the "Pages " prefix.
 */
export function parseVmStat(text: string): VmStat {
  const header = /page size of (\d+) bytes/.exec(text);
  if (!header) throw new Error("vm_stat: no page size");
  const pages: Record<string, number> = {};
  for (const line of text.split("\n")) {
    const m = /^Pages ([a-z -]+):\s+(\d+)\.?\s*$/i.exec(line.trim());
    if (m) pages[m[1].trim().toLowerCase()] = Number(m[2]);
  }
  return { pageSize: Number(header[1]), pages };
}

/**
 * Memory the host can hand out without compressing or swapping anything:
 * free, inactive, speculative and purgeable pages. Compressible memory is
 * left out on purpose. Compressing it to make room is the thrash the gate
 * exists to prevent.
 */
export function reclaimableBytes(vm: VmStat): number {
  const kinds = ["free", "inactive", "speculative", "purgeable"];
  const pages = kinds.reduce((n, k) => n + (vm.pages[k] ?? 0), 0);
  return pages * vm.pageSize;
}

const UNIT: Record<string, number> = { K: 2 ** 10, M: 2 ** 20, G: 2 ** 30 };

/** `sysctl -n vm.swapusage`: `total = 3072.00M  used = 1336.94M  free = …`. */
export function parseSwapUsage(text: string): {
  swapUsedBytes: number;
  swapTotalBytes: number;
} {
  const field = (name: string): number => {
    const m = new RegExp(`${name} = ([\\d.]+)([KMG])`).exec(text);
    if (!m) throw new Error(`vm.swapusage: no ${name}`);
    return Math.round(Number(m[1]) * UNIT[m[2]]);
  };
  return { swapUsedBytes: field("used"), swapTotalBytes: field("total") };
}

export async function readMemory(): Promise<Record<string, number | string>> {
  const [vm, swap] = await Promise.all([
    run("/usr/bin/vm_stat"),
    run("/usr/sbin/sysctl", ["-n", "vm.swapusage"]),
  ]);
  return {
    reclaimableBytes: reclaimableBytes(parseVmStat(vm.stdout)),
    ...parseSwapUsage(swap.stdout),
    at: new Date().toISOString(),
  };
}

/**
 * One reading per second at most, shared by every request in that second:
 * each reading runs two processes, and anything on the host, or any
 * container, can ask as often as it likes.
 */
const CACHE_MS = 1_000;
let cached: { at: number; reading: ReturnType<typeof readMemory> } | undefined;

export function cachedMemory(
  read: typeof readMemory = readMemory,
  now: number = Date.now(),
): ReturnType<typeof readMemory> {
  if (!cached || now - cached.at >= CACHE_MS) {
    const reading = read();
    cached = { at: now, reading };
    // A failed reading is not kept: the next request tries again.
    reading.catch(() => {
      if (cached?.reading === reading) cached = undefined;
    });
  }
  return cached.reading;
}

/**
 * Whether a request is addressed to this probe by a name it expects. A web
 * page in the desktop browser could otherwise point a domain it controls at
 * 127.0.0.1 (DNS rebinding) and read the numbers.
 */
export function allowedHost(header: string | undefined, port: number): boolean {
  const names = ["127.0.0.1", "localhost", "host.docker.internal"];
  return names.some((name) => header === `${name}:${port}`);
}

function serve(port: number, host: string): void {
  const server = createServer((req, res) => {
    if (!allowedHost(req.headers.host, port)) {
      res.writeHead(403).end();
      return;
    }
    if (req.method !== "GET" || req.url !== "/memory") {
      res.writeHead(404).end();
      return;
    }
    cachedMemory().then(
      (body) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(body));
      },
      (error: Error) => {
        // Answering 503 makes the gate fail closed, as silence would.
        res.writeHead(503, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: error.message }));
      },
    );
  });
  server.listen(port, host, () => {
    console.log(`host-memory-probe listening on http://${host}:${port}/memory`);
  });
}

// Compared as paths, not URLs: the installed copy lives under "Application
// Support", and a URL spells that space as %20.
const entry = process.argv[1] ? realpathSync(process.argv[1]) : "";
if (entry === realpathSync(fileURLToPath(import.meta.url))) {
  serve(Number(process.env.HOST_MEMORY_PROBE_PORT ?? 11500), "127.0.0.1");
}
