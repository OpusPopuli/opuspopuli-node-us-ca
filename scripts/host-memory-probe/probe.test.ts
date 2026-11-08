// Run: node --experimental-strip-types --test scripts/host-memory-probe/probe.test.ts
// (pnpm test:host-probe). Fixtures are real output shapes from macOS 27.2.
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  allowedHost,
  cachedMemory,
  parseSwapUsage,
  parseVmStat,
  reclaimableBytes,
} from "./probe.ts";

const VM_STAT = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                   523273.
Pages active:                                 991313.
Pages inactive:                              1085755.
Pages speculative:                             73813.
Pages throttled:                                   0.
Pages wired down:                             247226.
Pages purgeable:                               16569.
"Translation faults":                      415403897.
Pages stored in compressor:                   700000.
`;

test("reclaimable counts free, inactive, speculative and purgeable only", () => {
  const vm = parseVmStat(VM_STAT);
  assert.equal(vm.pageSize, 16384);
  assert.equal(vm.pages["wired down"], 247226);
  assert.equal(
    reclaimableBytes(vm),
    (523273 + 1085755 + 73813 + 16569) * 16384,
  );
});

test("a vm_stat without its page size is refused, not guessed", () => {
  assert.throws(() => parseVmStat("Pages free: 1."), /no page size/);
});

test("swap usage in any unit", () => {
  assert.deepEqual(
    parseSwapUsage(
      "total = 3072.00M  used = 1336.94M  free = 1735.06M  (encrypted)",
    ),
    {
      swapTotalBytes: 3072 * 2 ** 20,
      swapUsedBytes: Math.round(1336.94 * 2 ** 20),
    },
  );
  assert.equal(
    parseSwapUsage("total = 2.00G  used = 512.00K  free = 2.00G").swapUsedBytes,
    512 * 1024,
  );
});

test("answers only to the names it is reached by", () => {
  assert.ok(allowedHost("127.0.0.1:11500", 11500));
  assert.ok(allowedHost("localhost:11500", 11500));
  assert.ok(allowedHost("host.docker.internal:11500", 11500));
  assert.ok(!allowedHost("evil.example:11500", 11500));
  assert.ok(!allowedHost("127.0.0.1:80", 11500));
  assert.ok(!allowedHost(undefined, 11500));
});

test("shares one reading per second, and retries after a failure", async () => {
  let reads = 0;
  const ok = async () => ({ n: ++reads });
  await cachedMemory(ok, 10_000);
  await cachedMemory(ok, 10_500);
  assert.equal(reads, 1);
  await cachedMemory(ok, 11_000);
  assert.equal(reads, 2);

  const failing = () => Promise.reject(new Error("vm_stat failed"));
  await assert.rejects(cachedMemory(failing, 20_000));
  await new Promise((r) => setImmediate(r));
  await cachedMemory(ok, 20_100);
  assert.equal(reads, 3);
});
