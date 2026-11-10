import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const checker = path.join(root, "cmake/CheckWorkflow.cmake");
const nativePath = path.join(root, ".github/workflows/native.yml");
const checkScript = path.join(root, "scripts/check.sh");
const browserPackageScript = path.join(root, "scripts/check-browser-package.sh");
const expectedCheckScriptSha256 = "2e03ed0d0f3ebb101c129244f3289c7e10346c6cab14fe192fa833832947a37d";

function checkWorkflow(content, workflowKind = "native") {
  const directory = mkdtempSync(path.join(os.tmpdir(), "libfuturo-workflow-contract-"));
  const file = path.join(directory, "workflow.yml");
  try {
    writeFileSync(file, content);
    return spawnSync("cmake", [`-DWORKFLOW_FILE=${file}`, `-DWORKFLOW_KIND=${workflowKind}`, "-P", checker], {
      cwd: root,
      encoding: "utf8",
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function insertAfterWorkflowDispatch(source, insertedLine) {
  const marker = "  workflow_dispatch:";
  assert.equal(source.split(marker).length - 1, 1, "native workflow has one standalone workflow_dispatch event");
  return source.replace(marker, `${marker}\n${insertedLine}`);
}

test("native workflow contract accepts the recurring, unconditional qualification route", () => {
  const result = checkWorkflow(readFileSync(nativePath, "utf8"));
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});

test("the canonical native route remains byte-identical", () => {
  const result = spawnSync("shasum", ["-a", "256", checkScript], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim().split(/\s+/)[0], expectedCheckScriptSha256);
});

test("the native checker rejects each event inserted by the existing check.sh controls", () => {
  const source = readFileSync(nativePath, "utf8");
  const controls = [
    ["push", "unquoted"],
    ['"push"', "double-quoted"],
    ["'pull_request'", "single-quoted"],
    ['"\\u0070ush"', "escaped"],
    ["<<", "merge-key"],
  ];
  for (const [eventLine, label] of controls) {
    const result = checkWorkflow(insertAfterWorkflowDispatch(source, `  ${eventLine}:`));
    assert.notEqual(result.status, 0, `${label} mutation was accepted`);
    assert.match(`${result.stdout}\n${result.stderr}`, /workflow contract: unexpected trigger/,
      `${label} mutation failed for an unexpected reason`);
  }
});

test("native event coverage rejects a missing, duplicate, filtered, or conditional trigger", () => {
  const source = readFileSync(nativePath, "utf8");
  const mutations = [
    [source.replace("  pull_request:\n", ""), "missing pull_request"],
    [source.replace("  workflow_dispatch:\n", "  push:\n    branches: [main]\n  workflow_dispatch:\n"), "duplicate push"],
    [source.replace("    branches: [main]", "    branches: [main]\n    paths: [src/**]"), "filtered push"],
    [source.replace("    types: [checks_requested]", "    types: [opened]"), "filtered merge group"],
    [source.replace("    runs-on: macos-15", "    if: ${{ github.event_name == 'push' }}\n    runs-on: macos-15"), "job condition"],
  ];
  for (const [content, label] of mutations) {
    assert.notEqual(content, source, `${label} mutation did not match the authored workflow`);
    const result = checkWorkflow(content);
    assert.notEqual(result.status, 0, `${label} mutation was accepted`);
  }
});

test("browser workflow contract accepts one unconditional Linux qualification job", () => {
  const browserPath = path.join(root, ".github/workflows/browser.yml");
  const result = checkWorkflow(readFileSync(browserPath, "utf8"), "browser");
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});

test("browser container returns evidence ownership to the host runner", () => {
  const source = readFileSync(browserPackageScript, "utf8");
  assert.match(source, /readonly LIBFUTURO_RETURN_UID="\$\(id -u\)"/);
  assert.match(source, /readonly LIBFUTURO_RETURN_GID="\$\(id -g\)"/);
  assert.match(source, /-e LIBFUTURO_RETURN_UID="\$LIBFUTURO_RETURN_UID"/);
  assert.match(source, /-e LIBFUTURO_RETURN_GID="\$LIBFUTURO_RETURN_GID"/);
  assert.match(source, /chown -R "\$LIBFUTURO_RETURN_UID:\$LIBFUTURO_RETURN_GID" \/work\/evidence/);
});

test("browser workflow contract rejects trigger and coverage mutations", () => {
  const browserPath = path.join(root, ".github/workflows/browser.yml");
  const source = readFileSync(browserPath, "utf8");
  const mutations = [
    [source.replace("  pull_request:\n", ""), "missing pull_request"],
    [source.replace("    branches: [main]", "    branches: [release]"), "push branch filter drift"],
    [source.replace("  workflow_dispatch:\n", ""), "missing workflow_dispatch"],
    [source.replace("    types: [checks_requested]", "    types: [opened]"), "merge group activity drift"],
    [source.replace("  workflow_dispatch:\n", "  push:\n    branches: [main]\n  workflow_dispatch:\n"), "duplicate push"],
    [source.replace("  pull_request:\n", "  pull_request_target:\n"), "pull_request_target"],
    [source.replace("    name: Linux browser qualification", "    if: ${{ github.event_name == 'push' }}\n    name: Linux browser qualification"), "job guard"],
    [source.replace("      - name: Run canonical browser qualification", "      - name: Run canonical browser qualification\n        if: ${{ always() }}"), "step guard"],
  ];
  for (const [content, label] of mutations) {
    assert.notEqual(content, source, `${label} mutation did not match the authored workflow`);
    assert.notEqual(checkWorkflow(content, "browser").status, 0, `${label} mutation was accepted`);
  }
});

test("browser workflow contract rejects execution, timeout, pin, permission, and masking drift", () => {
  const browserPath = path.join(root, ".github/workflows/browser.yml");
  const source = readFileSync(browserPath, "utf8");
  const mutations = [
    [source.replace("runs-on: ubuntu-24.04", "runs-on: ubuntu-latest"), "runner drift"],
    [source.replace("timeout-minutes: 20", "timeout-minutes: 30"), "timeout drift"],
    [source.replace("run: ./scripts/check-browser-package.sh", "run: ./scripts/check-browser-package.sh --compile-only"), "command drift"],
    [source.replace("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7"), "weak checkout pin"],
    [source.replace("contents: read", "contents: write"), "write permission"],
    [source.replace("persist-credentials: false", "persist-credentials: true"), "persisted checkout credentials"],
    [source.replace("        run: ./scripts/check-browser-package.sh", "        run: ./scripts/check-browser-package.sh\n        continue-on-error: true"), "success masking"],
    [source.replace("  browser:\n", "  browser:\n    strategy:\n      matrix:\n        os: [ubuntu-24.04]\n"), "matrix expansion"],
  ];
  for (const [content, label] of mutations) {
    assert.notEqual(content, source, `${label} mutation did not match the authored workflow`);
    assert.notEqual(checkWorkflow(content, "browser").status, 0, `${label} mutation was accepted`);
  }
});
