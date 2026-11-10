import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { createPassingRun } from "./qualification-fixtures.mjs";
import { extractQualification, validateHostedEvidence } from "./hosted-evidence.mjs";

const CANDIDATE_SHA = "a".repeat(40);
const EXECUTED_MERGE_SHA = "f".repeat(40);
const BASE_SHA = "b".repeat(40);
const SOURCE_TREE = "9".repeat(40);
const PR_NUMBER = 42;
const PR_HEAD_REF = "gsd/browser-host";
const BASE_REF = "main";

function timestamp(offsetSeconds) {
  return new Date(Date.UTC(2026, 10, 10, 12, 0, offsetSeconds)).toISOString();
}

function makeJob({ route = "browser", runId = 701, sha = CANDIDATE_SHA } = {}) {
  const canonicalName = route === "browser"
    ? "Run canonical browser qualification"
    : "Run canonical checks";
  return {
    total_count: 1,
    jobs: [{
      id: runId + 1000,
      run_id: runId,
      head_sha: sha,
      name: route === "browser" ? "Linux browser qualification" : "macOS arm64 native checks",
      status: "completed",
      conclusion: "success",
      started_at: timestamp(10),
      completed_at: timestamp(100),
      steps: [
        { name: "Check out source", status: "completed", conclusion: "success",
          started_at: timestamp(12), completed_at: timestamp(20) },
        { name: canonicalName, status: "completed", conclusion: "success",
          started_at: timestamp(20), completed_at: timestamp(95) },
      ],
    }],
  };
}

function makeRun({ route = "browser", id = 701, headSha = CANDIDATE_SHA } = {}) {
  return {
    id,
    name: route === "browser" ? "Browser qualification" : "Native validation",
    repository: { full_name: "szTheory/libfuturo" },
    path: route === "browser"
      ? "szTheory/libfuturo/.github/workflows/browser.yml@refs/pull/42/merge"
      : "szTheory/libfuturo/.github/workflows/native.yml@refs/pull/42/merge",
    event: "pull_request",
    head_branch: PR_HEAD_REF,
    head_sha: headSha,
    status: "completed",
    conclusion: "success",
    run_attempt: 1,
    created_at: timestamp(0),
    run_started_at: timestamp(5),
    pull_requests: [{
      number: PR_NUMBER,
      head: { ref: PR_HEAD_REF, sha: CANDIDATE_SHA },
      base: { ref: BASE_REF, sha: BASE_SHA },
    }],
  };
}

function makePullRequest() {
  return {
    number: PR_NUMBER,
    head: { ref: PR_HEAD_REF, sha: CANDIDATE_SHA },
    base: { ref: BASE_REF, sha: BASE_SHA },
    merge_commit_sha: EXECUTED_MERGE_SHA,
    mergeable: true,
    merged: false,
  };
}

function makeHostedRunner({ runId = "701", workflow = "Browser qualification", job = "browser" } = {}) {
  return {
    kind: "github-actions",
    os: "linux",
    architecture: "x64",
    runner_name: { applicability: "observed", value: "GitHub Actions 2" },
    image_version: { applicability: "observed", value: "20261110.1" },
    github_actions: {
      applicability: "applicable",
      sha: EXECUTED_MERGE_SHA,
      run_id: runId,
      run_attempt: 1,
      workflow,
      job,
      event_name: "pull_request",
    },
  };
}

function clone(value) {
  return structuredClone(value);
}

async function passingFixture(t) {
  const fixture = await createPassingRun({
    sourceCommit: EXECUTED_MERGE_SHA,
    sourceTree: SOURCE_TREE,
    sourceSnapshotKind: "archived-head",
    outerRunner: makeHostedRunner(),
    runId: "qualification-run-01",
  });
  t.after(fixture.cleanup);
  return fixture;
}

function validInput(fixture) {
  return {
    run: makeRun(),
    jobs: makeJob(),
    qualification: fixture.report,
    expectedSource: CANDIDATE_SHA,
    pullRequest: makePullRequest(),
    nativeRun: makeRun({ route: "native", id: 702 }),
    nativeJobs: makeJob({ route: "native", runId: 702 }),
  };
}

test("accepts one complete first-attempt PR merge qualification and a separate native run", async t => {
  const fixture = await passingFixture(t);
  const result = validateHostedEvidence(validInput(fixture));
  assert.equal(result.valid, true, result.errors.join("; "));
  assert.equal(result.evidence.browser.qualification.scenario_count, 7);
  assert.equal(result.evidence.browser.candidate_head_sha, CANDIDATE_SHA);
  assert.equal(result.evidence.browser.qualification.executed_source_sha, EXECUTED_MERGE_SHA);
  assert.equal(result.evidence.browser.qualification.source_tree, SOURCE_TREE);
  assert.equal(result.evidence.browser.source_resolution.merge_sha_from_api, EXECUTED_MERGE_SHA);
  assert.equal(result.evidence.native.candidate_head_sha, CANDIDATE_SHA);
  assert.equal(result.evidence.browser.timings.queue.seconds, 10);
  assert.equal(result.evidence.browser.timings.setup_seconds, 8);
  assert.equal(result.evidence.browser.timings.canonical_step_seconds, 75);
  assert.equal(result.evidence.native.timings.canonical_step_seconds, 75);
  assert.equal(result.evidence.timing_definitions.queue.includes("created_at"), true);
  const finalizedFromLog = extractQualification(fixture.finalizeOutput);
  assert.equal(finalizedFromLog.marker, "final");
  assert.equal(finalizedFromLog.aggregate.status, "qualification-pass");
  assert.deepEqual(finalizedFromLog.aggregate.scenario_reports, fixture.report.scenario_reports);
});

test("extracts exactly one marked aggregate from a job log", async t => {
  const fixture = await passingFixture(t);
  const log = [
    "Starting canonical browser route",
    "=== LIBFUTURO_BROWSER_QUALIFICATION_BEGIN ===",
    JSON.stringify(fixture.report, null, 2),
    "=== LIBFUTURO_BROWSER_QUALIFICATION_END ===",
    "Result: PASS",
  ].join("\n");
  const extracted = extractQualification(log);
  assert.equal(extracted.aggregate.run_id, fixture.report.run_id);
  assert.equal(extracted.aggregate.status, "qualification-pass");
  assert.match(extracted.jsonText, /scenario_reports/);
  assert.throws(() => extractQualification(`${log}\n${log}`), /exactly one/);
  assert.throws(() => extractQualification("no report here"), /neither JSON nor a marked/);
});

test("selects the explicit final aggregate after provisional diagnostics and rejects duplicate final blocks", async t => {
  const fixture = await passingFixture(t);
  const provisional = clone(fixture.report);
  provisional.status = "qualification-finalizing";
  const log = [
    "=== LIBFUTURO_BROWSER_QUALIFICATION_BEGIN ===",
    JSON.stringify(provisional),
    "=== LIBFUTURO_BROWSER_QUALIFICATION_END ===",
    fixture.finalizeOutput,
  ].join("\n");
  const extracted = extractQualification(log);
  assert.equal(extracted.marker, "final");
  assert.equal(extracted.aggregate.status, "qualification-pass");
  assert.throws(() => extractQualification(`${log}\n${fixture.finalizeOutput}`), /exactly one final aggregate/);
});

test("fails closed for wrong source, run attempt, job multiplicity, job conclusion and canonical step state", async t => {
  const fixture = await passingFixture(t);
  const cases = [
    ["wrong expected source", input => { input.expectedSource = "c".repeat(40); }, /head SHA does not match/],
    ["wrong repository", input => { input.run.repository.full_name = "example/other"; }, /repository does not match/],
    ["wrong workflow path", input => { input.run.path = "szTheory/libfuturo/.github/workflows/other.yml@refs/pull/42/merge"; }, /workflow path does not identify/],
    ["untrusted workflow path prefix", input => { input.run.path = "untrusted-prefix/.github/workflows/browser.yml@refs/pull/42/merge"; }, /workflow path does not identify/],
    ["missing workflow path", input => { delete input.run.path; }, /workflow path does not identify/],
    ["run attempt two", input => { input.run.run_attempt = 2; }, /run_attempt=1/],
    ["missing job", input => { input.jobs.jobs = []; input.jobs.total_count = 0; }, /exactly one/],
    ["missing jobs total count", input => { delete input.jobs.total_count; }, /total_count does not match/],
    ["missing job ID", input => { delete input.jobs.jobs[0].id; }, /job ID is missing or invalid/],
    ["duplicate required job", input => { input.jobs.jobs.push(clone(input.jobs.jobs[0])); input.jobs.total_count = 2; }, /exactly one job/],
    ["failed job", input => { input.jobs.jobs[0].conclusion = "failure"; }, /job must have completed with success/],
    ["skipped job", input => { input.jobs.jobs[0].conclusion = "skipped"; }, /job must have completed with success/],
    ["cancelled job", input => { input.jobs.jobs[0].conclusion = "cancelled"; }, /job must have completed with success/],
    ["failed canonical step", input => { input.jobs.jobs[0].steps[1].conclusion = "failure"; }, /canonical browser qualification.*completed with success/],
    ["skipped canonical step", input => { input.jobs.jobs[0].steps[1].conclusion = "skipped"; }, /canonical browser qualification.*completed with success/],
    ["cancelled canonical step", input => { input.jobs.jobs[0].steps[1].conclusion = "cancelled"; }, /canonical browser qualification.*completed with success/],
  ];
  for (const [name, mutate, expected] of cases) {
    await t.test(name, () => {
      const input = clone(validInput(fixture));
      mutate(input);
      const result = validateHostedEvidence(input);
      assert.equal(result.valid, false);
      assert.ok(result.errors.some(error => expected.test(error)), result.errors.join("; "));
    });
  }
});

test("rejects missing report and mismatched source, run, job, artifact or merge identity", async t => {
  const fixture = await passingFixture(t);
  const cases = [
    ["missing aggregate", input => { input.qualification = null; }, /qualification report is missing/],
    ["source commit", input => { input.qualification.identity.source_commit = CANDIDATE_SHA; }, /source SHA does not match the recorded GITHUB_SHA/],
    ["run ID", input => { input.qualification.identity.outer_runner.github_actions.run_id = "999"; }, /GitHub run ID does not match/],
    ["job ID", input => { input.qualification.identity.outer_runner.github_actions.job = "native"; }, /job ID does not match/],
    ["browser artifact identity", input => { input.qualification.scenario_reports.identity.input.wasm_sha256 = "0".repeat(64); }, /consumer Wasm digest does not match/],
    ["missing embedded report", input => { delete input.qualification.scenario_reports["host-ui"]; }, /scenario_reports must contain exactly/],
    ["merge SHA", input => { input.pullRequest.merge_commit_sha = "c".repeat(40); }, /executed merge SHA does not match/],
    ["PR base SHA", input => { input.pullRequest.base.sha = "c".repeat(40); }, /base ref\/SHA does not match/],
    ["PR mergeability false", input => { input.pullRequest.mergeable = false; }, /mergeability must be true/],
    ["PR mergeability unknown", input => { input.pullRequest.mergeable = null; }, /mergeability must be true/],
    ["PR already merged", input => { input.pullRequest.merged = true; }, /must represent an unmerged PR test merge commit/],
  ];
  for (const [name, mutate, expected] of cases) {
    await t.test(name, () => {
      const input = clone(validInput(fixture));
      mutate(input);
      const result = validateHostedEvidence(input);
      assert.equal(result.valid, false);
      assert.ok(result.errors.some(error => expected.test(error)), result.errors.join("; "));
    });
  }
});

test("rejects native failure or a native run that does not bind to the same PR candidate", async t => {
  const fixture = await passingFixture(t);
  const cases = [
    ["native run attempt two", input => { input.nativeRun.run_attempt = 2; }, /native workflow run must be the first attempt/],
    ["native command failure", input => { input.nativeJobs.jobs[0].steps[1].conclusion = "failure"; }, /native 'Run canonical checks' step must have completed with success/],
    ["native source mismatch", input => { input.nativeRun.head_sha = "c".repeat(40); }, /native run head SHA does not match/],
    ["native base mismatch", input => { input.nativeRun.pull_requests[0].base.sha = "c".repeat(40); }, /native Pull Request API base ref\/SHA does not match/],
  ];
  for (const [name, mutate, expected] of cases) {
    await t.test(name, () => {
      const input = clone(validInput(fixture));
      mutate(input);
      const result = validateHostedEvidence(input);
      assert.equal(result.valid, false);
      assert.ok(result.errors.some(error => expected.test(error)), result.errors.join("; "));
    });
  }
});

test("records unavailable provider timestamps without estimating them", async t => {
  const fixture = await passingFixture(t);
  const input = validInput(fixture);
  delete input.jobs.jobs[0].started_at;
  delete input.jobs.jobs[0].steps[0].started_at;
  const result = validateHostedEvidence(input);
  assert.equal(result.valid, true, result.errors.join("; "));
  assert.deepEqual(result.evidence.browser.timings.queue, {
    status: "not-provided", seconds: null,
    definition: "workflow run created_at to required job started_at",
  });
  assert.equal(result.evidence.browser.timings.setup_seconds, null);
});

test("CLI validates saved API records, the final job-log aggregate, and PR metadata", async t => {
  const fixture = await passingFixture(t);
  const input = validInput(fixture);
  const paths = {
    run: path.join(fixture.root, "browser-run.json"),
    jobs: path.join(fixture.root, "browser-jobs.json"),
    qualification: path.join(fixture.root, "browser-job.log"),
    pullRequest: path.join(fixture.root, "pull-request.json"),
    nativeRun: path.join(fixture.root, "native-run.json"),
    nativeJobs: path.join(fixture.root, "native-jobs.json"),
  };
  writeFileSync(paths.run, JSON.stringify(input.run));
  writeFileSync(paths.jobs, JSON.stringify(input.jobs));
  writeFileSync(paths.qualification, fixture.finalizeOutput);
  writeFileSync(paths.pullRequest, JSON.stringify(input.pullRequest));
  writeFileSync(paths.nativeRun, JSON.stringify(input.nativeRun));
  writeFileSync(paths.nativeJobs, JSON.stringify(input.nativeJobs));

  const cli = fileURLToPath(new URL("./hosted-evidence.mjs", import.meta.url));
  const args = [cli, "--validate", "--run", paths.run, "--jobs", paths.jobs,
    "--qualification", paths.qualification, "--expected-source", CANDIDATE_SHA,
    "--pull-request", paths.pullRequest, "--native-run", paths.nativeRun, "--native-jobs", paths.nativeJobs];
  const passing = spawnSync(process.execPath, args, { encoding: "utf8" });
  assert.equal(passing.status, 0, passing.stderr);
  assert.equal(JSON.parse(passing.stdout).browser.qualification.executed_source_sha, EXECUTED_MERGE_SHA);

  const wrongSourceArgs = [...args];
  wrongSourceArgs[wrongSourceArgs.indexOf(CANDIDATE_SHA)] = "c".repeat(40);
  const wrongSource = spawnSync(process.execPath, wrongSourceArgs, { encoding: "utf8" });
  assert.notEqual(wrongSource.status, 0);
  assert.match(wrongSource.stderr, /expected candidate source|expected source/);
});
