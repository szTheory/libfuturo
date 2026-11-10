import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { test } from "node:test";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { SCENARIO_INVENTORY, runBrowserChild, runQualification, validateAggregate } from "./qualification.mjs";
import * as qualificationModule from "./qualification.mjs";
import { browserEnv, browserReportFor, consumerReport, createPassingRun, makeLogFiles } from "./qualification-fixtures.mjs";

const expectedScenarios = [
  "identity",
  "host-tracer",
  "host-content",
  "host-input",
  "host-input-audio",
  "host-lifecycle",
  "host-ui",
];

test("uses the exact seven-scenario browser qualification inventory", () => {
  assert.deepEqual(SCENARIO_INVENTORY, expectedScenarios);
});

test("runs every scenario once, serially, against one consumer identity", async () => {
  const calls = [];
  const consumer = consumerReport();
  const runId = "run-control-01";
  const root = mkdtempSync(path.join(os.tmpdir(), "browser-qualification-test-"));
  const reportPath = path.join(root, "browser-qualification.json");
  const evidenceDirectory = path.join(root, "qualification");
  const report = await runQualification({
    reportPath,
    evidenceDirectory,
    consumerReport: consumer,
    runId,
    env: browserEnv,
    spawnScenario: async spec => {
      calls.push(spec.scenario);
      writeFileSync(spec.stdoutPath, "", { mode: 0o600 });
      writeFileSync(spec.stderrPath, "", { mode: 0o600 });
      writeFileSync(spec.browserProcessLogPath, "", { mode: 0o600 });
      return {
        exitCode: 0,
        signal: null,
        timedOut: false,
        cancelled: false,
        browserReport: browserReportFor(spec.scenario, consumer),
      };
    },
  });

  assert.equal(report.status, "qualification-finalizing", report.failure?.validation_errors?.join("; ") ?? report.failure?.message);
  assert.deepEqual(calls, expectedScenarios);
  assert.deepEqual(report.results.map(result => result.scenario), expectedScenarios);
  assert.ok(report.results.every(result => result.attempt === 1));
  assert.ok(report.results.every(result => result.run_id === runId));
  assert.ok(report.results.every(result => result.status === "pass"));
});

test("embeds only the reviewed nested browser evidence fields in the aggregate", async t => {
  const root = mkdtempSync(path.join(os.tmpdir(), "browser-qualification-sanitized-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const consumer = consumerReport();
  consumer.container.node_versions.node = "22.15.0";
  consumer.container.node_versions.undici = "6.21.0";
  const report = await runQualification({
    reportPath: path.join(root, "browser-qualification.json"),
    evidenceDirectory: path.join(root, "qualification"),
    consumerReport: consumer,
    runId: "run-sanitized-control-01",
    env: browserEnv,
    spawnScenario: async spec => {
      makeLogFiles(spec);
      const browserReport = browserReportFor(spec.scenario, consumer);
      if (spec.scenario === "identity") {
        browserReport.unexpected_secret = "top-level-canary";
        browserReport.input.unexpected_secret = "input-canary";
        browserReport.input.link_command.unexpected_secret = "link-canary";
        browserReport.browser.unexpected_secret = "browser-canary";
        browserReport.container.unexpected_secret = "container-canary";
        browserReport.scenarios.unexpected_secret = "scenario-canary";
      }
      return { exitCode: 0, signal: null, timedOut: false, cancelled: false, browserReport };
    },
  });

  assert.equal(report.status, "qualification-finalizing", report.failure?.validation_errors?.join("; "));
  const embedded = report.scenario_reports.identity;
  assert.equal(Object.hasOwn(embedded, "unexpected_secret"), false);
  assert.equal(Object.hasOwn(embedded.input, "unexpected_secret"), false);
  assert.equal(Object.hasOwn(embedded.input.link_command, "unexpected_secret"), false);
  assert.equal(Object.hasOwn(embedded.browser, "unexpected_secret"), false);
  assert.equal(embedded.container.node_versions.node, "22.15.0");
  assert.equal(embedded.container.node_versions.undici, "6.21.0");
  assert.equal(Object.hasOwn(embedded.container, "unexpected_secret"), false);
  assert.equal(Object.hasOwn(embedded.scenarios, "unexpected_secret"), false);
});

test("rejects missing source tree provenance", async t => {
  const fixture = await makePassingRun(t);
  delete fixture.report.identity.source_tree;
  const validation = validateAggregate(copy(fixture.report), { baseDirectory: fixture.root });

  assert.equal(validation.valid, false);
  assert.ok(validation.errors.some(error => /source_tree/.test(error)),
    `expected a source_tree diagnostic, got: ${validation.errors.join("; ")}`);
});

test("rejects missing resolved SDK platform", async t => {
  const fixture = await makePassingRun(t);
  delete fixture.report.identity.sdk.resolved_platform;
  const validation = validateAggregate(copy(fixture.report), { baseDirectory: fixture.root });

  assert.equal(validation.valid, false);
  assert.ok(validation.errors.some(error => /resolved_platform/.test(error)),
    `expected a resolved_platform diagnostic, got: ${validation.errors.join("; ")}`);
});

test("rejects missing generated link command evidence", async t => {
  const fixture = await makePassingRun(t);
  delete fixture.report.identity.consumer.link_command;
  const validation = validateAggregate(copy(fixture.report), { baseDirectory: fixture.root });

  assert.equal(validation.valid, false);
  assert.ok(validation.errors.some(error => /link command/.test(error)),
    `expected a link command diagnostic, got: ${validation.errors.join("; ")}`);
});

test("rejects a consumer link command that shuts down the runtime after main", async t => {
  const fixture = await makePassingRun(t);
  const command = fixture.report.identity.consumer.link_command.command_text
    .replace("-sEXIT_RUNTIME=0", "-sEXIT_RUNTIME=1");
  fixture.report.identity.consumer.link_command = qualificationModule.parseGeneratedLinkCommand(
    command,
    { buildDirectory: "/work/consumer-build", relocatedPrefix: "/work/relocated" },
  );
  const validation = validateAggregate(copy(fixture.report), { baseDirectory: fixture.root });

  assert.equal(validation.valid, false);
  assert.ok(validation.errors.some(error => /-sEXIT_RUNTIME=0/.test(error)),
    `expected live-runtime diagnostic, got: ${validation.errors.join("; ")}`);
});

test("rejects browser reports from a different outer runner", async t => {
  const fixture = await makePassingRun(t);
  const browserReportPath = path.join(fixture.evidenceDirectory, "scenarios", "identity", "browser-report.json");
  const browserReport = JSON.parse(readFileSync(browserReportPath, "utf8"));
  browserReport.outer_runner = { ...browserReport.outer_runner, architecture: "x64" };
  writeFileSync(browserReportPath, `${JSON.stringify(browserReport)}\n`);
  const validation = validateAggregate(copy(fixture.report), { baseDirectory: fixture.root });

  assert.equal(validation.valid, false);
  assert.ok(validation.errors.some(error => /outer runner/.test(error)),
    `expected an outer runner mismatch, got: ${validation.errors.join("; ")}`);
});

test("parses ordered CMake link arguments and captures response-file contents", async t => {
  const parse = qualificationModule.parseGeneratedLinkCommand;
  assert.equal(typeof parse, "function", "the report builder must parse the actual generated link command");
  const root = mkdtempSync(path.join(os.tmpdir(), "browser-link-command-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, "CMakeFiles"), { recursive: true });
  const responseContents = "-sENVIRONMENT=web -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16";
  writeFileSync(path.join(root, "CMakeFiles", "consumer.rsp"), responseContents);
  const command = "emcc -O3 @CMakeFiles/consumer.rsp CMakeFiles/consumer.c.o -o artifacts/consumer.js /work/relocated/lib/libfuturo-web.a /work/relocated/lib/libmuhtari.a\n";
  const parsed = parse(command, { buildDirectory: root, relocatedPrefix: "/work/relocated" });

  assert.match(parsed.command_sha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(parsed.ordered_arguments, [
    "emcc", "-O3", "-sENVIRONMENT=web", "-sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16",
    "CMakeFiles/consumer.c.o", "-o", "artifacts/consumer.js",
    "/work/relocated/lib/libfuturo-web.a", "/work/relocated/lib/libmuhtari.a",
  ]);
  assert.equal(parsed.response_files[0].contents, responseContents);
  assert.match(parsed.normalized_command, /<relocated-prefix>\/lib\/libfuturo-web\.a/);
});

async function makePassingRun(t) {
  const fixture = await createPassingRun();
  t.after(fixture.cleanup);
  return fixture;
}

const copy = value => structuredClone(value);

function timingEvidence(aggregate) {
  const scenarios = Object.fromEntries(aggregate.results.map(result => [
    result.scenario,
    result.elapsed_seconds,
  ]));
  const scenarioExecution = Object.values(scenarios).reduce((sum, value) => sum + value, 0);
  const ns = seconds => seconds * 1e9;
  const containerIntervals = {
    package_configure: { start: ns(0), end: ns(1), unit: "nanoseconds" },
    package_build: { start: ns(1), end: ns(3), unit: "nanoseconds" },
    package_install_relocation: { start: ns(3), end: ns(6), unit: "nanoseconds" },
    consumer_configure: { start: ns(6), end: ns(7), unit: "nanoseconds" },
    consumer_build: { start: ns(7), end: ns(9), unit: "nanoseconds" },
    browser_setup: { start: ns(9), end: ns(10), unit: "nanoseconds" },
  };
  const scenarioIntervals = {};
  let scenarioStart = 0;
  for (const result of aggregate.results) {
    const duration = scenarios[result.scenario];
    scenarioIntervals[result.scenario] = {
      start: scenarioStart,
      end: scenarioStart + duration * 1000,
      unit: "milliseconds",
    };
    scenarioStart = scenarioIntervals[result.scenario].end;
  }
  return {
    schema_version: 1,
    finalized: true,
    clock_domains: {
      outer: "host CLOCK_MONOTONIC via Perl Time::HiRes",
      container: "SDK container CLOCK_MONOTONIC via Perl Time::HiRes",
      scenarios: "Node qualification-process performance.now()",
    },
    stage_clock_domains: {
      outer_setup_image_acquisition: "outer",
      docker_run: "outer",
      package_configure: "container",
      package_build: "container",
      package_install_relocation: "container",
      consumer_configure: "container",
      consumer_build: "container",
      browser_setup: "container",
      scenario_execution: "scenarios",
      scenarios: "scenarios",
      total: "outer",
    },
    durations_seconds: {
      outer_setup_image_acquisition: 2,
      docker_run: 10,
      package_configure: 1,
      package_build: 2,
      package_install_relocation: 3,
      consumer_configure: 1,
      consumer_build: 2,
      browser_setup: 1,
      scenario_execution: scenarioExecution,
      scenarios,
      total: 12,
    },
    intervals: {
      outer_setup_image_acquisition: { start: 0, end: ns(2), unit: "nanoseconds" },
      docker_run: { start: ns(2), end: ns(12), unit: "nanoseconds" },
      total: { start: 0, end: ns(12), unit: "nanoseconds" },
      ...containerIntervals,
      scenarios: scenarioIntervals,
    },
    cache_observations: {
      sdk_image: "verified-hit", browser_archive: "verified-hit", apt_packages: "not-claimed-unverified",
    },
    queue: {
      status: "not-available-locally",
      seconds: null,
      source: "hosted GitHub Actions run/job records only (Plan 03-05)",
    },
    nesting: {
      total_includes: ["outer_setup_image_acquisition", "docker_run"],
      docker_run_contains: ["package_configure", "package_build",
        "package_install_relocation", "consumer_configure", "consumer_build",
        "browser_setup", "scenario_execution"],
      scenario_execution: "sum-of-serial-scenario-intervals",
      warning: "container and scenario stage durations are nested inside docker_run; do not add them to total",
    },
  };
}

test("rejects missing, invalid, and contradictory timing evidence", async t => {
  const fixture = await makePassingRun(t);
  const valid = copy(fixture.report);
  valid.timings = timingEvidence(valid);
  assert.equal(validateAggregate(valid, { baseDirectory: fixture.root }).valid, true);

  const mutations = [
    ["missing stage", report => { delete report.timings.durations_seconds.package_configure; }, /package_configure/],
    ["negative duration", report => { report.timings.durations_seconds.package_build = -1; }, /package_build/],
    ["nonfinite duration", report => { report.timings.durations_seconds.consumer_build = Infinity; }, /consumer_build/],
    ["wrong clock domain", report => { report.timings.stage_clock_domains.browser_setup = "outer"; }, /browser_setup/],
    ["missing scenario duration", report => { delete report.timings.durations_seconds.scenarios.identity; }, /identity/],
    ["scenario total mismatch", report => { report.timings.durations_seconds.scenario_execution += 1; }, /scenario_execution/],
    ["scenario differs from result", report => { report.timings.durations_seconds.scenarios.identity += 1; }, /identity/],
    ["total shorter than setup", report => { report.timings.durations_seconds.total = 1; }, /total/],
    ["Docker duration contradiction", report => { report.timings.durations_seconds.docker_run = 11; }, /docker_run/],
    ["invented local queue time", report => { report.timings.queue = { status: "observed", seconds: 4, source: "local wall clock" }; }, /queue/],
    ["missing nesting contract", report => { delete report.timings.nesting; }, /nesting/],
    ["missing stage boundary", report => { delete report.timings.intervals.consumer_configure; }, /consumer_configure/],
    ["negative scenario boundary", report => { report.timings.intervals.scenarios.identity.start = -1; }, /identity/],
    ["nonfinite outer boundary", report => { report.timings.intervals.total.end = NaN; }, /total/],
  ];
  for (const [name, mutate, expectedError] of mutations) {
    await t.test(name, () => {
      const report = copy(valid);
      mutate(report);
      const validation = validateAggregate(report, { baseDirectory: fixture.root });
      assert.equal(validation.valid, false);
      assert.ok(validation.errors.some(error => expectedError.test(error)),
        `expected ${expectedError}, got: ${validation.errors.join("; ")}`);
    });
  }
});

test("rejects each independent scenario-result failure with its class diagnostic", async t => {
  const fixture = await makePassingRun(t);
  const mutations = [
    ["missing", report => report.results.pop(), /missing scenario result/],
    ["duplicate", report => { report.results[1].scenario = "identity"; }, /duplicate scenario result/],
    ["unknown", report => { report.results[1].scenario = "unknown-scenario"; }, /unknown scenario result/],
    ["skipped", report => { report.results[0].status = "not-run"; }, /result status is not pass/],
    ["cancelled", report => { report.results[0].child.cancelled = true; }, /child cancelled must be false/],
    ["timeout", report => { report.results[0].child.timed_out = true; }, /child timed_out must be false/],
    ["failed", report => { report.results[0].status = "failed"; }, /result status is not pass/],
    ["nonzero child", report => { report.results[0].child.exit_code = 7; }, /child exit_code must equal zero/],
    ["signalled child", report => { report.results[0].child.signal = "SIGTERM"; }, /child signal must be null/],
    ["mismatched run", report => { report.results[0].run_id = "another-run-01"; }, /run_id does not match aggregate/],
    ["retried", report => { report.results[0].retry_history = [{ attempt: 1 }]; }, /retry_history must be an empty array/],
    ["attempt two", report => { report.results[0].attempt = 2; }, /attempt must equal one/],
  ];
  for (const [name, mutate, expectedError] of mutations) {
    await t.test(name, () => {
      const report = copy(fixture.report);
      mutate(report);
      const validation = validateAggregate(report, { baseDirectory: fixture.root });
      assert.equal(validation.valid, false);
      assert.ok(validation.errors.some(error => expectedError.test(error)),
        `expected ${expectedError}, got: ${validation.errors.join("; ")}`);
    });
  }
});

test("rejects absent, null, and incorrectly typed identity or child facts", async t => {
  const fixture = await makePassingRun(t);
  const mutations = [
    ["missing identity", report => { delete report.identity; }, /identity must be a JSON object/],
    ["null source commit", report => { report.identity.source_commit = null; }, /source_commit must be a 40-character commit SHA/],
    ["string API revision", report => { report.identity.package.api_revision = "8"; }, /package.api_revision must be a positive integer/],
    ["null fixture identity", report => { report.identity.fixture_metadata = null; }, /fixture_metadata must be a JSON object/],
    ["number browser revision", report => { report.identity.browser.release_revision = 1717349; }, /release_revision must be a numeric revision/],
    ["missing child facts", report => { delete report.results[0].child; }, /child facts are missing/],
    ["missing result status", report => { delete report.results[0].status; }, /result status is not pass/],
    ["string child exit code", report => { report.results[0].child.exit_code = "0"; }, /child exit_code must equal zero/],
    ["null attempt", report => { report.results[0].attempt = null; }, /attempt must equal one/],
    ["null retry history", report => { report.results[0].retry_history = null; }, /retry_history must be an empty array/],
  ];
  for (const [name, mutate, expectedError] of mutations) {
    await t.test(name, () => {
      const report = copy(fixture.report);
      mutate(report);
      const validation = validateAggregate(report, { baseDirectory: fixture.root });
      assert.equal(validation.valid, false);
      assert.ok(validation.errors.some(error => expectedError.test(error)),
        `expected ${expectedError}, got: ${validation.errors.join("; ")}`);
    });
  }
});

test("rejects single-field mutations across source, runner, build, browser, and runtime identity", async t => {
  const fixture = await makePassingRun(t);
  const digest = value => value.repeat(64);
  const mutations = [
    ["source commit", report => { report.identity.source_commit = "0".repeat(40); }],
    ["source tree", report => { report.identity.source_tree = "0".repeat(40); }],
    ["source snapshot kind", report => { report.identity.source_snapshot_kind = "archived-head"; }],
    ["package target", report => { report.identity.package.target = "other::target"; }],
    ["core name", report => { report.identity.package.core = "other-core"; }],
    ["core version", report => { report.identity.package.core_version = "0.0.0"; }],
    ["core source revision", report => { report.identity.package.core_source_revision = "0".repeat(40); }],
    ["profile", report => { report.identity.package.profile = "other-profile"; }],
    ["configuration", report => { report.identity.package.configuration = "other-config"; }],
    ["build ID", report => { report.identity.package.libfuturo_build_id = "other-build"; }],
    ["API revision", report => { report.identity.package.api_revision += 1; }],
    ["ABI revision", report => { report.identity.package.abi_revision += 1; }],
    ["behavior revision", report => { report.identity.package.behavior_revision += 1; }],
    ["web archive", report => { report.identity.package.archive_sha256 = digest("9"); }],
    ["core archive", report => { report.identity.package.core_archive_sha256 = digest("9"); }],
    ["fixture ID", report => { report.identity.fixture_metadata.id = "other-fixture"; }],
    ["fixture size", report => { report.identity.fixture_metadata.bytes += 1; }],
    ["fixture digest", report => { report.identity.fixture_metadata.sha256 = digest("9"); }],
    ["fixture loaded flag", report => { report.identity.fixture_metadata.loaded_or_read = true; }],
    ["SDK image", report => { report.identity.sdk.image = `emscripten/emsdk:7.0.0@sha256:${digest("9")}`; }],
    ["requested SDK platform", report => { report.identity.sdk.requested_platform = "linux/arm64"; }],
    ["resolved SDK platform", report => { report.identity.sdk.resolved_platform = "linux/arm64"; }],
    ["SDK container architecture", report => { report.identity.sdk.container_architecture = "arm64"; }],
    ["compiler", report => { report.identity.sdk.compiler = "different compiler"; }],
    ["consumer JavaScript", report => { report.identity.consumer.javascript_sha256 = digest("9"); }],
    ["host controller", report => { report.identity.consumer.host_controller_sha256 = digest("9"); }],
    ["consumer Wasm", report => { report.identity.consumer.wasm_sha256 = digest("9"); }],
    ["generated command digest", report => { report.identity.consumer.link_command.command_sha256 = digest("9"); }],
    ["generated command text", report => { report.identity.consumer.link_command.command_text += " -sASSERTIONS=1"; }],
    ["normalized command", report => { report.identity.consumer.link_command.normalized_command = "emcc different"; }],
    ["link path token", report => { report.identity.consumer.link_command.normalizations[0].token = "<arbitrary>"; }],
    ["ordered link settings", report => { report.identity.consumer.link_command.ordered_arguments.pop(); }],
    ["browser version", report => { report.identity.browser.version = "156.0.1"; }],
    ["browser archive", report => { report.identity.browser.archive_sha256 = digest("9"); }],
    ["browser release revision", report => { report.identity.browser.release_revision = "123"; }],
    ["browser platform", report => { report.identity.browser.requested_platform = "linux/arm64"; }],
    ["runtime package classification", report => { report.identity.browser.runtime_packages_classification = "pinned"; }],
    ["runtime package inventory", report => { report.identity.browser.runtime_packages[0] = "other-package=1.0"; }],
    ["outer runner OS", report => { report.identity.outer_runner.os = "linux"; }],
    ["outer runner architecture", report => { report.identity.outer_runner.architecture = "x64"; }],
    ["hosted source SHA", report => {
      report.identity.outer_runner = {
        kind: "github-actions", os: "ubuntu", architecture: "x64",
        runner_name: { applicability: "observed", value: "GitHub Actions 2" },
        image_version: { applicability: "observed", value: "20261101.1" },
        github_actions: {
          applicability: "applicable", sha: "b".repeat(40), run_id: "12345", run_attempt: 1,
          workflow: "browser", job: "qualify", event_name: "push",
        },
      };
    }],
    ["hosted retry attempt", report => {
      report.identity.outer_runner = {
        kind: "github-actions", os: "ubuntu", architecture: "x64",
        runner_name: { applicability: "not-provided", value: null },
        image_version: { applicability: "not-provided", value: null },
        github_actions: {
          applicability: "applicable", sha: report.identity.source_commit, run_id: "12345", run_attempt: 2,
          workflow: "browser", job: "qualify", event_name: "push",
        },
      };
    }],
    ["local GitHub SHA", report => { report.identity.outer_runner.github_actions.sha = "a".repeat(40); }],
    ["Docker daemon", report => { report.identity.docker_daemon.platform = "linux/amd64"; }],
    ["container OS", report => { report.identity.container.os_name = "Debian"; }],
    ["container architecture", report => { report.identity.container.architecture = "arm64"; }],
    ["Node version", report => { report.identity.container.node_version = "v99.0.0"; }],
    ["Node platform", report => { report.identity.container.node_platform = "darwin"; }],
    ["Node architecture", report => { report.identity.container.node_architecture = "arm64"; }],
    ["Node modules ABI", report => { report.identity.container.node_versions.modules = "0"; }],
  ];
  for (const [name, mutate] of mutations) {
    await t.test(name, () => {
      const report = copy(fixture.report);
      mutate(report);
      const validation = validateAggregate(report, { baseDirectory: fixture.root });
      assert.equal(validation.valid, false, `${name} unexpectedly passed identity validation`);
    });
  }
});

test("rejects report mismatch, stale metadata, path traversal, and status conflicts", async t => {
  const fixture = await makePassingRun(t);
  for (const [name, mutate, expectedError] of [
    ["path traversal", report => { report.results[0].browser_report = "../../outside.json"; }, /browser report reference is unsafe/],
    ["status and child conflict", report => { report.results[0].child.exit_code = 2; }, /child exit_code must equal zero/],
  ]) {
    await t.test(name, () => {
      const report = copy(fixture.report);
      mutate(report);
      const validation = validateAggregate(report, { baseDirectory: fixture.root });
      assert.equal(validation.valid, false);
      assert.ok(validation.errors.some(error => expectedError.test(error)),
        `expected ${expectedError}, got: ${validation.errors.join("; ")}`);
    });
  }

  const browserReportPath = path.join(fixture.evidenceDirectory, "scenarios", "identity", "browser-report.json");
  const original = readFileSync(browserReportPath, "utf8");
  for (const [name, mutate, expectedError] of [
    ["mismatched consumer", report => { report.input.wasm_sha256 = "9".repeat(64); }, /consumer Wasm digest does not match/],
    ["mismatched core version", report => { report.input.core_version = "0.0.0"; }, /core version does not match/],
    ["mismatched core revision", report => { report.input.core_source_revision = "9".repeat(40); }, /core source revision does not match/],
    ["mismatched ABI revision", report => { report.input.abi_revision = 2; }, /ABI revision does not match/],
    ["malformed browser report JSON", null, /browser report could not be read/],
    ["stale run ID", report => { report.qualification.run_id = "stale-run-01"; }, /browser report is stale or has mismatched run/],
    ["browser failure with child success", report => { report.status = "browser-failed"; }, /browser report status conflicts with a passing child/],
  ]) {
    await t.test(name, () => {
      const browserReport = JSON.parse(original);
      if (name === "malformed browser report JSON") {
        writeFileSync(browserReportPath, "{\n");
        const validation = validateAggregate(copy(fixture.report), { baseDirectory: fixture.root });
        assert.equal(validation.valid, false);
        assert.ok(validation.errors.some(error => expectedError.test(error)),
          `expected ${expectedError}, got: ${validation.errors.join("; ")}`);
        writeFileSync(browserReportPath, original);
        return;
      }
      mutate(browserReport);
      writeFileSync(browserReportPath, `${JSON.stringify(browserReport)}\n`);
      const validation = validateAggregate(copy(fixture.report), { baseDirectory: fixture.root });
      assert.equal(validation.valid, false);
      assert.ok(validation.errors.some(error => expectedError.test(error)),
        `expected ${expectedError}, got: ${validation.errors.join("; ")}`);
      writeFileSync(browserReportPath, original);
    });
  }
});

test("rejects lifecycle results without a queued source retired by the hidden event", async t => {
  const fixture = await makePassingRun(t);
  const reportPath = path.join(fixture.evidenceDirectory, "scenarios", "host-lifecycle", "browser-report.json");
  const original = readFileSync(reportPath, "utf8");
  const mutations = [
    ["no queued audio", lifecycle => { lifecycle.audio_retirement.queued_before_hide = false; }],
    ["empty queue", lifecycle => { lifecycle.audio_retirement.queue_samples_before_hide = 0; }],
    ["no source retirement", lifecycle => { lifecycle.audio_retirement.source_retired_on_hide = false; }],
    ["no stopped-source delta", lifecycle => {
      lifecycle.audio_retirement.sources_stopped_after_hide = lifecycle.audio_retirement.sources_stopped_before_hide;
    }],
  ];
  for (const [name, mutate] of mutations) {
    await t.test(name, () => {
      const browserReport = JSON.parse(original);
      mutate(browserReport.scenarios.lifecycle);
      writeFileSync(reportPath, `${JSON.stringify(browserReport)}\n`);
      const validation = validateAggregate(copy(fixture.report), { baseDirectory: fixture.root });
      assert.equal(validation.valid, false);
      assert.ok(validation.errors.some(error => /lifecycle CDP evidence lacks audio retirement/.test(error)),
        `expected a lifecycle audio-retirement diagnostic, got: ${validation.errors.join("; ")}`);
      writeFileSync(reportPath, original);
    });
  }
});

test("CLI validation accepts a complete pass and rejects malformed or failing reports", async t => {
  const fixture = await makePassingRun(t);
  const cli = fileURLToPath(new URL("./qualification.mjs", import.meta.url));
  const passing = spawnSync(process.execPath, [cli, "--validate", fixture.reportPath], { encoding: "utf8" });
  assert.equal(passing.status, 0, passing.stderr);
  assert.match(passing.stdout, /Qualification validation: PASS/);

  const failingPath = path.join(fixture.root, "failing-aggregate.json");
  const failingAggregate = copy(fixture.report);
  failingAggregate.results[0].status = "not-run";
  writeFileSync(failingPath, JSON.stringify(failingAggregate));
  const failing = spawnSync(process.execPath, [cli, "--validate", failingPath], { encoding: "utf8" });
  assert.equal(failing.status, 1);
  assert.match(failing.stderr, /Qualification validation: FAIL/);

  const malformedPath = path.join(fixture.root, "malformed-aggregate.json");
  writeFileSync(malformedPath, "{\n");
  const malformed = spawnSync(process.execPath, [cli, "--validate", malformedPath], { encoding: "utf8" });
  assert.equal(malformed.status, 1);
  assert.match(malformed.stderr, /Qualification validation: FAIL/);
});

test("failure stops after one attempt and cancellation does not spawn later scenarios", async t => {
  const root = mkdtempSync(path.join(os.tmpdir(), "browser-qualification-failure-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const consumer = consumerReport();
  const attempts = [];
  const failed = await runQualification({
    reportPath: path.join(root, "browser-qualification.json"),
    evidenceDirectory: path.join(root, "qualification"),
    consumerReport: consumer,
    runId: "run-failure-control-01",
    env: browserEnv,
    spawnScenario: async spec => {
      attempts.push(spec.scenario);
      makeLogFiles(spec);
      return { exitCode: attempts.length === 1 ? 9 : 0, signal: null, timedOut: false,
        cancelled: false, browserReport: browserReportFor(spec.scenario, consumer) };
    },
  });
  assert.equal(failed.status, "qualification-failed");
  assert.deepEqual(attempts, ["identity"]);
  assert.equal(failed.results[0].status, "failed");
  assert.equal(failed.results[1].status, "not-run");
  assert.deepEqual(failed.results[0].retry_history, []);

  const cancelledRoot = mkdtempSync(path.join(os.tmpdir(), "browser-qualification-cancel-"));
  t.after(() => rmSync(cancelledRoot, { recursive: true, force: true }));
  const controller = new AbortController();
  const calls = [];
  const started = performance.now();
  const cancelled = await runQualification({
    reportPath: path.join(cancelledRoot, "browser-qualification.json"),
    evidenceDirectory: path.join(cancelledRoot, "qualification"),
    consumerReport: consumer,
    runId: "run-cancel-control-01",
    env: browserEnv,
    signal: controller.signal,
    spawnScenario: async (spec, { signal }) => {
      calls.push(spec.scenario);
      assert.equal(signal, controller.signal);
      makeLogFiles(spec);
      setTimeout(() => controller.abort(), 10);
      await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }));
      return { exitCode: null, signal: "SIGTERM", timedOut: false, cancelled: true };
    },
  });
  assert.ok(performance.now() - started < 1_000, "fake child cancellation should return promptly");
  assert.deepEqual(calls, ["identity"]);
  assert.equal(cancelled.status, "qualification-failed");
  assert.equal(cancelled.results[0].status, "cancelled");
  assert.equal(cancelled.results[1].status, "not-run");
  assert.deepEqual(cancelled.results[0].retry_history, []);
});

test("refuses existing aggregate and evidence paths instead of reusing stale reports", async t => {
  const root = mkdtempSync(path.join(os.tmpdir(), "browser-qualification-stale-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const consumer = consumerReport();
  const reportPath = path.join(root, "browser-qualification.json");
  const evidenceDirectory = path.join(root, "qualification");

  await t.test("existing aggregate path", async () => {
    writeFileSync(reportPath, "stale");
    await assert.rejects(runQualification({ reportPath, evidenceDirectory, consumerReport: consumer,
      runId: "run-stale-control-01", env: browserEnv }), /refusing stale report reuse/);
    rmSync(reportPath);
  });

  await t.test("existing evidence directory", async () => {
    const staleScenario = path.join(evidenceDirectory, "scenarios", "identity");
    mkdirSync(staleScenario, { recursive: true });
    writeFileSync(path.join(staleScenario, "browser-report.json"), "stale");
    await assert.rejects(runQualification({ reportPath, evidenceDirectory, consumerReport: consumer,
      runId: "run-stale-control-02", env: browserEnv,
      spawnScenario: async spec => {
        makeLogFiles(spec);
        return { exitCode: 0, signal: null, timedOut: false, cancelled: false,
          browserReport: browserReportFor(spec.scenario, consumer) };
      } }), /refusing stale scenario evidence reuse/);
  });
});

test("propagates cancellation to an unresponsive fake child and bounds cleanup", async t => {
  const root = mkdtempSync(path.join(os.tmpdir(), "browser-qualification-child-cancel-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const controller = new AbortController();
  const stderrPath = path.join(root, "child.stderr.log");
  const started = performance.now();
  const outcomePromise = runBrowserChild({
    executable: process.execPath,
    args: ["-e", "process.on('SIGTERM', () => process.stderr.write('SIGTERM delivered\\n')); process.stderr.write('READY\\n'); setInterval(() => {}, 1000)"],
    env: process.env,
    stdoutPath: path.join(root, "child.stdout.log"),
    stderrPath,
  }, { signal: controller.signal, timeoutMs: 15_000 });
  const readyDeadline = performance.now() + 2_000;
  let childReady = false;
  while (performance.now() < readyDeadline) {
    try { childReady = readFileSync(stderrPath, "utf8").includes("READY"); }
    catch { /* child log stream may not have opened yet */ }
    if (childReady) break;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  controller.abort();
  const outcome = await outcomePromise;

  assert.equal(childReady, true, "fake child must install its SIGTERM handler before cancellation");
  assert.equal(outcome.cancelled, true);
  assert.equal(outcome.timedOut, false);
  assert.equal(outcome.signal, "SIGKILL");
  assert.equal(outcome.cleanupTimedOut, false);
  assert.ok(performance.now() - started < 7_000, "unresponsive child cleanup must be bounded");
  assert.match(readFileSync(stderrPath, "utf8"), /SIGTERM delivered/);
});
