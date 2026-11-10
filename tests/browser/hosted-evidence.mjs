import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { SCENARIO_INVENTORY, validateAggregate } from "./qualification.mjs";

const BEGIN_MARKER = "=== LIBFUTURO_BROWSER_QUALIFICATION_BEGIN ===";
const END_MARKER = "=== LIBFUTURO_BROWSER_QUALIFICATION_END ===";
const FINAL_BEGIN_MARKER = "=== LIBFUTURO_BROWSER_QUALIFICATION_FINAL_BEGIN ===";
const FINAL_END_MARKER = "=== LIBFUTURO_BROWSER_QUALIFICATION_FINAL_END ===";
const MAX_EVIDENCE_FILE_BYTES = 16 * 1024 * 1024;
const REPOSITORY = "szTheory/libfuturo";
const ROUTES = Object.freeze({
  browser: {
    workflow: "Browser qualification",
    workflowPath: ".github/workflows/browser.yml",
    jobId: "browser",
    jobName: "Linux browser qualification",
    canonicalStep: "Run canonical browser qualification",
  },
  native: {
    workflow: "Native validation",
    workflowPath: ".github/workflows/native.yml",
    jobId: "native",
    jobName: "macOS arm64 native checks",
    canonicalStep: "Run canonical checks",
  },
});
const ALLOWED_EVENTS = new Set(["pull_request", "push", "workflow_dispatch", "merge_group"]);

function objectLike(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function stringId(value) {
  if (typeof value === "string" && value.length > 0) return value;
  if (Number.isSafeInteger(value) && value > 0) return String(value);
  return null;
}

function timestampDuration(startValue, endValue, label, errors) {
  if (startValue === undefined || startValue === null || endValue === undefined || endValue === null) {
    return { status: "not-provided", seconds: null };
  }
  if (typeof startValue !== "string" || typeof endValue !== "string" ||
      !Number.isFinite(Date.parse(startValue)) || !Number.isFinite(Date.parse(endValue))) {
    errors.push(`${label} timestamps are present but invalid`);
    return { status: "invalid", seconds: null };
  }
  const delta = Date.parse(endValue) - Date.parse(startValue);
  if (delta < 0) {
    errors.push(`${label} end timestamp precedes its start timestamp`);
    return { status: "invalid", seconds: null };
  }
  return { status: "observed", seconds: delta / 1000 };
}

function oneStep(job, name, label, errors) {
  if (!Array.isArray(job?.steps)) {
    errors.push(`${label} job steps are missing`);
    return null;
  }
  const matching = job.steps.filter(step => step?.name === name);
  if (matching.length !== 1) {
    errors.push(`${label} must contain exactly one '${name}' step`);
    return null;
  }
  const step = matching[0];
  if (step.status !== "completed" || step.conclusion !== "success") {
    errors.push(`${label} '${name}' step must have completed with success`);
  }
  return step;
}

function validateRoute({ routeName, run, jobs, expectedSource, errors }) {
  const spec = ROUTES[routeName];
  if (!objectLike(run)) {
    errors.push(`${routeName} run metadata is missing or malformed`);
    return null;
  }
  if (!objectLike(jobs) || !Array.isArray(jobs.jobs)) {
    errors.push(`${routeName} jobs metadata is missing or malformed`);
    return null;
  }

  const runId = stringId(run.id);
  if (!runId) errors.push(`${routeName} run ID is missing or invalid`);
  if (run.name !== spec.workflow) errors.push(`${routeName} workflow name does not match '${spec.workflow}'`);
  if (run.repository?.full_name !== REPOSITORY) {
    errors.push(`${routeName} workflow run repository does not match '${REPOSITORY}'`);
  }
  const workflowPath = typeof run.path === "string" ? run.path.split("@", 1)[0] : "";
  const acceptedWorkflowPaths = new Set([spec.workflowPath, `${REPOSITORY}/${spec.workflowPath}`]);
  if (!acceptedWorkflowPaths.has(workflowPath)) {
    errors.push(`${routeName} workflow path does not identify '${spec.workflowPath}'`);
  }
  if (run.status !== "completed" || run.conclusion !== "success") {
    errors.push(`${routeName} workflow run must have completed with success`);
  }
  if (run.run_attempt !== 1) {
    errors.push(`${routeName} workflow run must be the first attempt (run_attempt=1)`);
  }
  if (!ALLOWED_EVENTS.has(run.event)) errors.push(`${routeName} run event is not one of the recurring workflow triggers`);
  if (run.head_sha !== expectedSource) {
    errors.push(`${routeName} run head SHA does not match the expected candidate source`);
  }
  const pullRequests = Array.isArray(run.pull_requests) ? run.pull_requests : [];
  if (run.event === "pull_request") {
    const matchingPullRequests = pullRequests.filter(pr => pr?.head?.sha === expectedSource);
    if (matchingPullRequests.length !== 1) {
      errors.push(`${routeName} pull_request metadata must bind exactly one PR head to the expected candidate SHA`);
    }
  }

  if (jobs.total_count !== jobs.jobs.length) {
    errors.push(`${routeName} jobs total_count does not match the returned job list`);
  }
  if (jobs.jobs.length !== 1) errors.push(`${routeName} run must contain exactly one job`);
  const namedJobs = jobs.jobs.filter(job => job?.name === spec.jobName);
  if (namedJobs.length !== 1) errors.push(`${routeName} run must contain exactly one '${spec.jobName}' job`);
  const job = namedJobs.length === 1 ? namedJobs[0] : null;
  if (!job) return null;

  if (!Number.isSafeInteger(job.id) || job.id <= 0) errors.push(`${routeName} job ID is missing or invalid`);
  if (stringId(job.run_id) !== runId) errors.push(`${routeName} job run ID does not match its workflow run`);
  if (job.head_sha !== expectedSource) errors.push(`${routeName} job source SHA does not match the expected source`);
  if (job.status !== "completed" || job.conclusion !== "success") {
    errors.push(`${routeName} job must have completed with success`);
  }
  if (job.run_attempt !== undefined && job.run_attempt !== run.run_attempt) {
    errors.push(`${routeName} job attempt does not match workflow run attempt`);
  }

  const checkout = oneStep(job, "Check out source", routeName, errors);
  const canonical = oneStep(job, spec.canonicalStep, routeName, errors);
  const jobTiming = timestampDuration(job.started_at, job.completed_at, `${routeName} job execution`, errors);
  const queueTiming = timestampDuration(run.created_at, job.started_at, `${routeName} queue`, errors);
  const setupTiming = checkout
    ? timestampDuration(checkout.started_at, checkout.completed_at, `${routeName} checkout setup`, errors)
    : { status: "not-provided", seconds: null };
  const commandTiming = canonical
    ? timestampDuration(canonical.started_at, canonical.completed_at, `${routeName} canonical step`, errors)
    : { status: "not-provided", seconds: null };

  return {
    run_id: runId,
    workflow: run.name,
    event: run.event,
    candidate_head_sha: run.head_sha,
    pull_requests: pullRequests.map(pr => ({
      number: Number.isSafeInteger(pr?.number) ? pr.number : null,
      head_sha: typeof pr?.head?.sha === "string" ? pr.head.sha : null,
      base_sha: typeof pr?.base?.sha === "string" ? pr.base.sha : null,
      merge_commit_sha: typeof pr?.merge_commit_sha === "string" ? pr.merge_commit_sha : null,
    })),
    attempt: run.run_attempt,
    job_id: stringId(job.id),
    job_name: job.name,
    status: job.status,
    conclusion: job.conclusion,
    steps: {
      checkout: { name: checkout?.name ?? "Check out source", ...setupTiming },
      canonical: { name: canonical?.name ?? spec.canonicalStep, ...commandTiming },
    },
    timings: {
      queue: {
        ...queueTiming,
        definition: "workflow run created_at to required job started_at",
      },
      job_execution: {
        ...jobTiming,
        definition: "required job started_at to completed_at",
      },
      setup_seconds: setupTiming.seconds,
      canonical_step_seconds: commandTiming.seconds,
    },
  };
}

function validatePullRequestBinding({ run, pullRequest, expectedSource, label, errors }) {
  if (run?.event !== "pull_request") return null;
  if (!objectLike(pullRequest)) {
    errors.push(`${label} pull_request event requires saved Pull Request API metadata`);
    return null;
  }
  const runReferences = (Array.isArray(run.pull_requests) ? run.pull_requests : [])
    .filter(pr => pr?.head?.sha === expectedSource);
  if (runReferences.length !== 1) {
    errors.push(`${label} Actions run must identify exactly one PR whose head matches the expected candidate SHA`);
    return null;
  }
  const runPr = runReferences[0];
  if (pullRequest.head?.sha !== expectedSource) {
    errors.push(`${label} Pull Request API head SHA does not match the expected candidate SHA`);
  }
  if (!Number.isSafeInteger(pullRequest.number) || pullRequest.number !== runPr.number) {
    errors.push(`${label} Pull Request API number does not match the Actions run metadata`);
  }
  if (pullRequest.head?.ref !== runPr.head?.ref) {
    errors.push(`${label} Pull Request API head ref does not match the Actions run metadata`);
  }
  if (pullRequest.base?.ref !== runPr.base?.ref || pullRequest.base?.sha !== runPr.base?.sha) {
    errors.push(`${label} Pull Request API base ref/SHA does not match the Actions run metadata`);
  }
  const mergeSha = pullRequest.merge_commit_sha;
  if (pullRequest.mergeable !== true) {
    errors.push(`${label} Pull Request API mergeability must be true before accepting merge SHA evidence`);
  }
  if (pullRequest.merged !== false) {
    errors.push(`${label} Pull Request API must represent an unmerged PR test merge commit`);
  }
  if (typeof mergeSha !== "string" || !/^[a-f0-9]{40}$/.test(mergeSha)) {
    errors.push(`${label} Pull Request API merge_commit_sha is missing or malformed`);
  }
  return {
    number: pullRequest.number ?? null,
    head_sha: pullRequest.head?.sha ?? null,
    base_sha: pullRequest.base?.sha ?? null,
    base_ref: pullRequest.base?.ref ?? null,
    merge_commit_sha: typeof mergeSha === "string" ? mergeSha : null,
    mergeable: pullRequest.mergeable ?? null,
    merged: pullRequest.merged ?? null,
  };
}

export function extractQualification(text) {
  if (typeof text !== "string") throw new Error("qualification evidence must be text");
  const beginCount = text.split(BEGIN_MARKER).length - 1;
  const endCount = text.split(END_MARKER).length - 1;
  const finalBeginCount = text.split(FINAL_BEGIN_MARKER).length - 1;
  const finalEndCount = text.split(FINAL_END_MARKER).length - 1;
  const hasFinal = finalBeginCount > 0 || finalEndCount > 0;
  if (hasFinal) {
    if (finalBeginCount !== 1 || finalEndCount !== 1) {
      throw new Error("qualification log must contain exactly one final aggregate marker pair");
    }
    if (beginCount !== endCount || beginCount > 1) {
      throw new Error("qualification log contains malformed or duplicate provisional aggregate markers");
    }
    const begin = text.indexOf(FINAL_BEGIN_MARKER) + FINAL_BEGIN_MARKER.length;
    const end = text.indexOf(FINAL_END_MARKER);
    if (end < begin) throw new Error("final qualification aggregate end marker precedes its begin marker");
    const jsonText = text.slice(begin, end).trim();
    try {
      return { aggregate: JSON.parse(jsonText), jsonText, marker: "final" };
    } catch {
      throw new Error("final marked qualification aggregate is not valid JSON");
    }
  }
  if (beginCount === 0 && endCount === 0) {
    const trimmed = text.trim();
    try {
      return { aggregate: JSON.parse(trimmed), jsonText: trimmed };
    } catch {
      throw new Error("qualification evidence is neither JSON nor a marked browser aggregate");
    }
  }
  if (beginCount !== 1 || endCount !== 1) {
    throw new Error("qualification log must contain exactly one aggregate begin/end marker pair");
  }
  const begin = text.indexOf(BEGIN_MARKER) + BEGIN_MARKER.length;
  const end = text.indexOf(END_MARKER);
  if (end < begin) throw new Error("qualification aggregate end marker precedes its begin marker");
  const jsonText = text.slice(begin, end).trim();
  try {
    return { aggregate: JSON.parse(jsonText), jsonText, marker: "provisional-or-legacy" };
  } catch {
    throw new Error("marked qualification aggregate is not valid JSON");
  }
}

function qualificationFrom(input) {
  if (typeof input === "string") return extractQualification(input);
  if (objectLike(input)) {
    const jsonText = JSON.stringify(input);
    return { aggregate: input, jsonText };
  }
  throw new Error("qualification report is missing or malformed");
}

function validateBrowserAggregate({ aggregate, jsonText, run, pullRequestBinding, expectedSource, errors }) {
  const validation = validateAggregate(aggregate, {
    baseDirectory: process.cwd(),
    requireEmbeddedScenarioReports: true,
  });
  errors.push(...validation.errors.map(error => `qualification: ${error}`));

  if (aggregate?.status !== "qualification-pass") errors.push("qualification aggregate is not a passing report");
  const executedSource = aggregate?.identity?.source_commit;
  if (typeof executedSource !== "string" || !/^[a-f0-9]{40}$/.test(executedSource)) {
    errors.push("qualification executed source SHA is missing or malformed");
  }
  if (aggregate?.identity?.source_snapshot_kind !== "archived-head") {
    errors.push("qualification source must be an archived committed HEAD");
  }
  const runner = aggregate?.identity?.outer_runner;
  const github = runner?.github_actions;
  if (runner?.kind !== "github-actions") errors.push("qualification report must identify a GitHub Actions runner");
  if (runner?.os !== "linux" || runner?.architecture !== "x64") {
    errors.push("qualification report outer runner must be Linux x64");
  }
  if (github?.sha !== executedSource) errors.push("qualification source SHA does not match the recorded GITHUB_SHA");
  if (run?.event === "pull_request") {
    if (pullRequestBinding?.merge_commit_sha !== executedSource) {
      errors.push("qualification executed merge SHA does not match the Pull Request API merge_commit_sha");
    }
  } else if (executedSource !== expectedSource || github?.sha !== expectedSource) {
    errors.push("qualification executed source SHA does not match the expected non-PR candidate SHA");
  }
  if (stringId(github?.run_id) !== stringId(run?.id)) errors.push("qualification GitHub run ID does not match the API run");
  if (github?.run_attempt !== 1 || github?.run_attempt !== run?.run_attempt) {
    errors.push("qualification GitHub run attempt does not match the first-attempt API run");
  }
  if (github?.workflow !== run?.name) errors.push("qualification workflow name does not match the API run");
  if (github?.job !== ROUTES.browser.jobId) errors.push("qualification GitHub job ID does not match the stable browser job");
  if (github?.event_name !== run?.event) errors.push("qualification event name does not match the API run");

  return {
    status: "validated",
    candidate_head_sha: expectedSource,
    executed_source_sha: executedSource ?? null,
    source_tree: aggregate?.identity?.source_tree ?? null,
    pull_request: pullRequestBinding,
    aggregate_run_id: aggregate?.run_id ?? null,
    scenario_count: aggregate?.results?.length ?? null,
    scenario_inventory: aggregate?.scenario_inventory ?? null,
    report_sha256: sha256(jsonText),
    timings: aggregate?.timings ?? null,
  };
}

export function validateHostedEvidence({
  run,
  jobs,
  qualification,
  expectedSource,
  pullRequest = undefined,
  nativeRun = undefined,
  nativeJobs = undefined,
} = {}) {
  const errors = [];
  if (typeof expectedSource !== "string" || !/^[a-f0-9]{40}$/.test(expectedSource)) {
    errors.push("expected source must be a 40-character lowercase commit SHA");
  }
  const source = typeof expectedSource === "string" ? expectedSource : "";
  const browser = validateRoute({ routeName: "browser", run, jobs, expectedSource: source, errors });
  const browserPullRequest = validatePullRequestBinding({
    run,
    pullRequest,
    expectedSource: source,
    label: "browser",
    errors,
  });
  let parsedQualification = null;
  try {
    parsedQualification = qualificationFrom(qualification);
  } catch (error) {
    errors.push(error.message);
  }
  let browserQualification = null;
  if (parsedQualification) {
    browserQualification = validateBrowserAggregate({
      aggregate: parsedQualification.aggregate,
      jsonText: parsedQualification.jsonText,
      run,
      pullRequestBinding: browserPullRequest,
      expectedSource: source,
      errors,
    });
  }

  const nativeProvided = nativeRun !== undefined || nativeJobs !== undefined;
  let native = null;
  if (nativeProvided) {
    if (nativeRun === undefined || nativeJobs === undefined) {
      errors.push("native evidence requires both --native-run and --native-jobs");
    } else {
      native = validateRoute({ routeName: "native", run: nativeRun, jobs: nativeJobs, expectedSource: source, errors });
      const nativePullRequest = validatePullRequestBinding({
        run: nativeRun,
        pullRequest,
        expectedSource: source,
        label: "native",
        errors,
      });
      if (nativePullRequest && browserPullRequest &&
          (nativePullRequest.number !== browserPullRequest.number ||
           nativePullRequest.head_sha !== browserPullRequest.head_sha ||
           nativePullRequest.base_sha !== browserPullRequest.base_sha ||
           nativePullRequest.merge_commit_sha !== browserPullRequest.merge_commit_sha)) {
        errors.push("native and browser workflow evidence do not resolve to the same PR head/base/merge SHA");
      }
      if (native && nativePullRequest) native.pull_request = nativePullRequest;
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    evidence: errors.length === 0 ? {
      schema_version: 1,
      expected_source: source,
      browser: {
        ...browser,
        qualification: browserQualification,
        source_resolution: browserQualification ? {
          event: run?.event ?? null,
          candidate_head_sha: expectedSource,
          executed_source_sha: browserQualification.executed_source_sha,
          source_tree: browserQualification.source_tree,
          merge_sha_from_api: browserPullRequest?.merge_commit_sha ?? null,
          pull_request_number: browserPullRequest?.number ?? null,
          pull_request_base_sha: browserPullRequest?.base_sha ?? null,
          pull_request_base_ref: browserPullRequest?.base_ref ?? null,
          executed_identity_basis: "report GITHUB_SHA equals archived checkout HEAD; report tree and all seven embedded scenario identities validate against that SHA/tree",
        } : null,
      },
      native,
      timing_definitions: {
        queue: "workflow run created_at to required job started_at; includes orchestration and runner wait",
        job_execution: "required job started_at to completed_at",
        setup_seconds: "Check out source step started_at to completed_at",
        canonical_step_seconds: "canonical run step started_at to completed_at",
        qualification_stages: "validated aggregate timings; stage clock domains and nested intervals are preserved from the report",
      },
      limitations: [
        "Jobs API exposes only the latest attempt; the workflow run's run_attempt is checked explicitly and must equal one.",
        "For pull_request events, the Actions API head SHA identifies the PR candidate; GITHUB_SHA identifies the checked-out merge commit. Saved Pull Request API metadata binds head/base and merge_commit_sha to the report's executed SHA.",
        "GitHub Actions evidence binds source lineage and result identity; it is not authentication or a security attestation.",
        "Branch-protection enforcement is not observable from these run/job records.",
      ],
    } : null,
  };
}

function parseArguments(args) {
  if (args[0] !== "--validate") throw new Error("expected --validate");
  const values = new Map();
  for (let index = 1; index < args.length; index += 2) {
    const name = args[index];
    const value = args[index + 1];
    if (!name?.startsWith("--") || value === undefined || value.startsWith("--")) {
      throw new Error("arguments must be --name FILE pairs");
    }
    if (!new Set(["--run", "--jobs", "--qualification", "--expected-source", "--pull-request", "--native-run", "--native-jobs"]).has(name)) {
      throw new Error(`unsupported option ${name}`);
    }
    if (values.has(name)) throw new Error(`duplicate option ${name}`);
    values.set(name, value);
  }
  for (const required of ["--run", "--jobs", "--qualification", "--expected-source"]) {
    if (!values.has(required)) throw new Error(`missing required option ${required}`);
  }
  if (values.has("--native-run") !== values.has("--native-jobs")) {
    throw new Error("native evidence requires both --native-run and --native-jobs");
  }
  return values;
}

function readEvidence(pathname, label, { text = false } = {}) {
  const absolute = path.resolve(pathname);
  const stat = statSync(absolute);
  if (!stat.isFile() || stat.size > MAX_EVIDENCE_FILE_BYTES) {
    throw new Error(`${label} evidence must be a regular file no larger than 16 MiB`);
  }
  const contents = readFileSync(absolute, "utf8");
  if (text) return contents;
  try { return JSON.parse(contents); }
  catch { throw new Error(`${label} evidence is not valid JSON`); }
}

function usage() {
  return "Usage: node tests/browser/hosted-evidence.mjs --validate --run RUN.json --jobs JOBS.json --qualification REPORT.json --expected-source SHA [--pull-request PR.json] [--native-run RUN.json --native-jobs JOBS.json]";
}

async function runCli() {
  try {
    const options = parseArguments(process.argv.slice(2));
    const result = validateHostedEvidence({
      run: readEvidence(options.get("--run"), "browser run"),
      jobs: readEvidence(options.get("--jobs"), "browser jobs"),
      qualification: readEvidence(options.get("--qualification"), "browser qualification", { text: true }),
      expectedSource: options.get("--expected-source"),
      ...(options.has("--pull-request") ? { pullRequest: readEvidence(options.get("--pull-request"), "pull request") } : {}),
      ...(options.has("--native-run") ? {
        nativeRun: readEvidence(options.get("--native-run"), "native run"),
        nativeJobs: readEvidence(options.get("--native-jobs"), "native jobs"),
      } : {}),
    });
    if (!result.valid) {
      process.stderr.write(`Hosted evidence validation: FAIL\n${result.errors.map(error => `- ${error}`).join("\n")}\n`);
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${JSON.stringify(result.evidence, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`Hosted evidence validation: FAIL (${error.message})\n${usage()}\n`);
    process.exitCode = 2;
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await runCli();
}
