import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import test from "node:test";

test("host Stop destroys once and stale callbacks make no public calls", t => {
  const run = spawnSync("bash", ["scripts/check-browser-host-worktree.sh", "host-lifecycle"], {
    cwd: process.cwd(),
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    timeout: 300_000,
  });
  const output = `${run.stdout ?? ""}${run.stderr ?? ""}`;
  const preserved = [...output.matchAll(/Preserved browser scenario evidence: ([^\s]+)/g)].at(-1);
  assert.ok(preserved, `host-lifecycle did not preserve its browser report (exit ${run.status})`);
  const reportPath = `${process.cwd()}/${preserved[1]}/browser-report.json`;
  const report = JSON.parse(readFileSync(reportPath, "utf8"));
  t.diagnostic(`Preserved browser scenario evidence: ${preserved[1]}`);
  const lifecycle = report.page_results?.lifecycle;
  assert.ok(lifecycle, `host-lifecycle did not return assertions: ${JSON.stringify({
    status: report.status,
    failure: report.failure,
  })}`);
  assert.equal(lifecycle.stop_destroys_once, true);
  assert.equal(lifecycle.stale_callback_no_calls, true);
});
