import { createHash, randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import {
  closeSync,
  createWriteStream,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const SCENARIO_INVENTORY = Object.freeze([
  "identity",
  "host-tracer",
  "host-content",
  "host-input",
  "host-input-audio",
  "host-lifecycle",
  "host-ui",
]);

const CHILD_TIMEOUT_MS = 180_000;
const CHILD_KILL_GRACE_MS = 5_000;
const CHILD_CLEANUP_LIMIT_MS = 12_000;
const REPORT_SCHEMA_VERSION = 2;
const SCENARIO_EVIDENCE_KEY = Object.freeze({
  identity: ["positive", "mismatch"],
  "host-tracer": ["tracer"],
  "host-content": ["content"],
  "host-input": ["input"],
  "host-input-audio": ["audio"],
  "host-lifecycle": ["lifecycle"],
  "host-ui": ["ui"],
});

const TIMING_STAGE_DOMAINS = Object.freeze({
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
});

const TIMING_CLOCK_DOMAINS = Object.freeze({
  outer: "host CLOCK_MONOTONIC via Perl Time::HiRes",
  container: "SDK container CLOCK_MONOTONIC via Perl Time::HiRes",
  scenarios: "Node qualification-process performance.now()",
});

const TIMING_NESTING = Object.freeze({
  total_includes: ["outer_setup_image_acquisition", "docker_run"],
  docker_run_contains: ["package_configure", "package_build",
    "package_install_relocation", "consumer_configure", "consumer_build",
    "browser_setup", "scenario_execution"],
  scenario_execution: "sum-of-serial-scenario-intervals",
  warning: "container and scenario stage durations are nested inside docker_run; do not add them to total",
});

function objectLike(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function sha256(value) {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}

function digestSha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function shellArguments(command) {
  const args = [];
  let token = "";
  let quote = null;
  let escaped = false;
  let started = false;
  for (const character of command) {
    if (escaped) {
      token += character;
      escaped = false;
      started = true;
      continue;
    }
    if (character === "\\" && quote !== "'") {
      escaped = true;
      started = true;
      continue;
    }
    if (quote !== null) {
      if (character === quote) quote = null;
      else token += character;
      started = true;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      started = true;
      continue;
    }
    if (/\s/.test(character)) {
      if (started) args.push(token);
      token = "";
      started = false;
      continue;
    }
    token += character;
    started = true;
  }
  if (escaped || quote !== null) throw new Error("generated link command has unclosed quoting");
  if (started) args.push(token);
  return args;
}

function pathInside(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function responseReferences(argument) {
  const references = [];
  if (argument.startsWith("@")) references.push(argument.slice(1));
  for (const match of argument.matchAll(/(?:^|[,=])@([^,\s]+)/g)) {
    if (!references.includes(match[1])) references.push(match[1]);
  }
  return references.filter(Boolean);
}

export function parseGeneratedLinkCommand(commandText, {
  buildDirectory,
  relocatedPrefix,
  sourceRoot = "/src",
  packageBuildDirectory = "/work/build",
  stagingDirectory = "/work/stage",
} = {}) {
  if (typeof commandText !== "string" || commandText.trim().length === 0) {
    throw new Error("generated link command must be a non-empty string");
  }
  if (!nonEmptyString(buildDirectory) || !nonEmptyString(relocatedPrefix)) {
    throw new Error("generated link command build and relocated paths are required");
  }
  const buildRoot = path.resolve(buildDirectory);
  const responseFiles = [];
  const responseFilesByPath = new Map();
  const expanded = [];
  const expand = (argument, ancestry = []) => {
    if (argument.startsWith("@")) {
      const reference = argument.slice(1);
      const resolved = path.resolve(buildRoot, reference);
      if (!pathInside(buildRoot, resolved)) throw new Error("link response file escapes the consumer build directory");
      if (ancestry.includes(resolved) || ancestry.length >= 8) {
        throw new Error("link response file nesting is cyclic or too deep");
      }
      let response = responseFilesByPath.get(resolved);
      if (!response) {
        const contents = readFileSync(resolved, "utf8");
        response = {
          reference,
          path: path.relative(buildRoot, resolved).split(path.sep).join("/"),
          contents,
          sha256: digestSha256(contents),
        };
        responseFilesByPath.set(resolved, response);
        responseFiles.push(response);
      }
      for (const nested of shellArguments(response.contents)) expand(nested, [...ancestry, resolved]);
      return;
    }
    for (const reference of responseReferences(argument).filter(value => !argument.startsWith(`@${value}`))) {
      const resolved = path.resolve(buildRoot, reference);
      if (!pathInside(buildRoot, resolved)) throw new Error("link response file escapes the consumer build directory");
      if (!responseFilesByPath.has(resolved)) {
        const contents = readFileSync(resolved, "utf8");
        const response = {
          reference,
          path: path.relative(buildRoot, resolved).split(path.sep).join("/"),
          contents,
          sha256: digestSha256(contents),
        };
        responseFilesByPath.set(resolved, response);
        responseFiles.push(response);
      }
    }
    expanded.push(argument);
  };
  const commandArguments = shellArguments(commandText);
  for (const argument of commandArguments) expand(argument);

  const normalizations = [
    { source_path: buildRoot, token: "<consumer-build>" },
    { source_path: path.resolve(relocatedPrefix), token: "<relocated-prefix>" },
    ...(sourceRoot ? [{ source_path: path.resolve(sourceRoot), token: "<source-root>" }] : []),
    ...(packageBuildDirectory ? [{ source_path: path.resolve(packageBuildDirectory), token: "<package-build>" }] : []),
    ...(stagingDirectory ? [{ source_path: path.resolve(stagingDirectory), token: "<staging-prefix>" }] : []),
  ].sort((left, right) => right.source_path.length - left.source_path.length);
  let normalizedCommand = commandText;
  for (const normalization of normalizations) {
    normalizedCommand = normalizedCommand.split(normalization.source_path).join(normalization.token);
  }
  return {
    command_text: commandText,
    command_sha256: digestSha256(commandText),
    normalized_command: normalizedCommand,
    normalized_command_sha256: digestSha256(normalizedCommand),
    normalizations,
    command_arguments: commandArguments,
    ordered_arguments: expanded,
    response_files: responseFiles,
  };
}

function isoTime(value) {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function identityFromConsumer(consumerReport, env) {
  const browserVersion = env.LIBFUTURO_BROWSER_VERSION;
  const browserArchiveSha = env.LIBFUTURO_BROWSER_ARCHIVE_SHA256;
  const browserRevision = env.LIBFUTURO_CFT_REVISION;
  const platform = env.LIBFUTURO_SDK_PLATFORM;
  return {
    source_commit: consumerReport.source_commit,
    source_tree: consumerReport.source_tree,
    source_snapshot_kind: consumerReport.source_snapshot_kind ?? env.LIBFUTURO_SOURCE_SNAPSHOT ?? "archived-head",
    outer_runner: clone(consumerReport.outer_runner),
    docker_daemon: clone(consumerReport.docker_daemon),
    container: clone(consumerReport.container),
    package: clone(consumerReport.package),
    fixture_metadata: clone(consumerReport.fixture_metadata),
    sdk: clone(consumerReport.sdk),
    consumer: {
      javascript_sha256: consumerReport.consumer.javascript_sha256,
      host_controller_sha256: consumerReport.consumer.host_controller_sha256,
      wasm_sha256: consumerReport.consumer.wasm_sha256,
      link_command: clone(consumerReport.consumer.link_command),
    },
    browser: {
      version: browserVersion,
      archive_sha256: browserArchiveSha,
      release_revision: browserRevision,
      requested_platform: platform,
      runtime_packages_classification: consumerReport.browser?.runtime_packages_classification,
      runtime_packages: clone(consumerReport.browser?.runtime_packages),
    },
    identity_assurance: "lineage-and-mismatch-detection; not authentication or attestation",
  };
}

function outerRunnerErrors(runner) {
  const errors = [];
  if (!objectLike(runner)) return ["identity.outer_runner must be a JSON object"];
  if (!new Set(["local", "github-actions"]).has(runner.kind)) {
    errors.push("identity.outer_runner.kind must be local or github-actions");
  }
  if (!nonEmptyString(runner.os) || !nonEmptyString(runner.architecture)) {
    errors.push("identity.outer_runner OS and architecture must be observed strings");
  }
  for (const key of ["runner_name", "image_version"]) {
    const fact = runner[key];
    if (!objectLike(fact) || !new Set(["observed", "not-provided", "not-applicable"]).has(fact.applicability) ||
        !(fact.value === null || nonEmptyString(fact.value)) ||
        (fact.applicability === "observed" && !nonEmptyString(fact.value)) ||
        (fact.applicability !== "observed" && fact.value !== null)) {
      errors.push(`identity.outer_runner.${key} must identify observed or inapplicable data`);
    }
    if (runner.kind === "local" && fact?.applicability !== "not-applicable") {
      errors.push(`identity.outer_runner.${key} must be not-applicable for a local run`);
    }
    if (runner.kind === "github-actions" && fact?.applicability === "not-applicable") {
      errors.push(`identity.outer_runner.${key} cannot be not-applicable for a hosted run`);
    }
  }

  const github = runner.github_actions;
  if (!objectLike(github)) {
    errors.push("identity.outer_runner.github_actions must be a JSON object");
  } else if (runner.kind === "local") {
    if (github.applicability !== "not-applicable" ||
        ["sha", "run_id", "run_attempt", "workflow", "job", "event_name"].some(key => github[key] !== null)) {
      errors.push("identity.outer_runner GitHub Actions facts must be explicitly not-applicable locally");
    }
  } else {
    if (github.applicability !== "applicable") {
      errors.push("identity.outer_runner GitHub Actions facts must be applicable on a hosted run");
    }
    if (typeof github.sha !== "string" || !/^[a-f0-9]{40}$/.test(github.sha)) {
      errors.push("identity.outer_runner.github_actions.sha must be a 40-character commit SHA");
    }
    if (!nonEmptyString(github.run_id) || !Number.isSafeInteger(github.run_attempt) || github.run_attempt !== 1 ||
        !nonEmptyString(github.workflow) || !nonEmptyString(github.job) || !nonEmptyString(github.event_name)) {
      errors.push("identity.outer_runner GitHub Actions run, workflow, job, event, and first attempt are required");
    }
  }
  return errors;
}

function linkCommandErrors(linkCommand) {
  const errors = [];
  if (!objectLike(linkCommand)) return ["identity.consumer link command must be a JSON object"];
  if (!nonEmptyString(linkCommand.command_text) || !sha256(linkCommand.command_sha256) ||
      digestSha256(linkCommand.command_text ?? "") !== linkCommand.command_sha256) {
    errors.push("identity.consumer link command text and digest are required and must match");
  }
  if (!nonEmptyString(linkCommand.normalized_command) || !sha256(linkCommand.normalized_command_sha256) ||
      digestSha256(linkCommand.normalized_command ?? "") !== linkCommand.normalized_command_sha256) {
    errors.push("identity.consumer normalized link command and digest are required and must match");
  }
  if (!Array.isArray(linkCommand.normalizations) ||
      linkCommand.normalizations.some(item => !objectLike(item) || !nonEmptyString(item.source_path) || !nonEmptyString(item.token))) {
    errors.push("identity.consumer link command path normalizations are missing or malformed");
  } else {
    const expectedNormalizations = new Map([
      ["/work/consumer-build", "<consumer-build>"],
      ["/work/relocated", "<relocated-prefix>"],
      ["/src", "<source-root>"],
      ["/work/build", "<package-build>"],
      ["/work/stage", "<staging-prefix>"],
    ]);
    if (linkCommand.normalizations.length !== expectedNormalizations.size ||
        linkCommand.normalizations.some(item => expectedNormalizations.get(item.source_path) !== item.token)) {
      errors.push("identity.consumer link command normalizations must use the documented ephemeral paths only");
    }
    let expectedNormalized = linkCommand.command_text ?? "";
    for (const item of [...linkCommand.normalizations].sort((left, right) => right.source_path.length - left.source_path.length)) {
      expectedNormalized = expectedNormalized.split(item.source_path).join(item.token);
    }
    if (expectedNormalized !== linkCommand.normalized_command) {
      errors.push("identity.consumer normalized link command does not follow its declared path tokens");
    }
  }

  let commandArguments;
  try { commandArguments = shellArguments(linkCommand.command_text ?? ""); }
  catch { commandArguments = null; }
  if (!Array.isArray(linkCommand.command_arguments) ||
      JSON.stringify(linkCommand.command_arguments) !== JSON.stringify(commandArguments)) {
    errors.push("identity.consumer raw link command arguments do not match the generated command text");
  }

  if (!Array.isArray(linkCommand.ordered_arguments) ||
      linkCommand.ordered_arguments.some(argument => typeof argument !== "string")) {
    errors.push("identity.consumer ordered link arguments are missing or malformed");
  } else {
    if (!Array.isArray(linkCommand.response_files)) {
      errors.push("identity.consumer link response files must be an array");
    } else {
      const responseMap = new Map(linkCommand.response_files.map(response => [response?.reference, response]));
      const expanded = [];
      const expand = (argument, ancestry = []) => {
        if (!argument.startsWith("@")) {
          expanded.push(argument);
          return;
        }
        const reference = argument.slice(1);
        const response = responseMap.get(reference);
        if (!response || ancestry.includes(reference) || ancestry.length >= 8) return;
        for (const nested of shellArguments(response.contents)) expand(nested, [...ancestry, reference]);
      };
      for (const argument of commandArguments ?? []) expand(argument);
      if (JSON.stringify(expanded) !== JSON.stringify(linkCommand.ordered_arguments)) {
        errors.push("identity.consumer ordered link arguments do not match the generated command and response files");
      }
    }
    for (const required of ["-sENVIRONMENT=web", "-sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16", "-sEXIT_RUNTIME=0",
      "/work/relocated/lib/libfuturo-web.a", "/work/relocated/lib/libmuhtari.a"]) {
      if (!linkCommand.ordered_arguments.includes(required)) {
        errors.push(`identity.consumer ordered link arguments are missing ${required}`);
      }
    }
  }

  if (!Array.isArray(linkCommand.response_files)) {
    errors.push("identity.consumer link response files must be an array");
  } else {
    const responseMap = new Map(linkCommand.response_files.map(response => [response?.reference, response]));
    for (const [index, response] of linkCommand.response_files.entries()) {
      if (!objectLike(response) || !nonEmptyString(response.reference) || !nonEmptyString(response.path) ||
          typeof response.contents !== "string" || !sha256(response.sha256) ||
          digestSha256(response.contents ?? "") !== response.sha256) {
        errors.push(`identity.consumer link response file ${index} is missing content or a matching digest`);
      } else if (path.posix.isAbsolute(response.reference) || path.posix.isAbsolute(response.path) ||
          response.reference.split(/[\\/]/).includes("..") || response.path.split(/[\\/]/).includes("..") ||
          response.path !== response.reference.split("\\").join("/")) {
        errors.push(`identity.consumer link response file ${index} escapes or misidentifies the build directory`);
      }
    }
    for (const argument of commandArguments ?? []) {
      for (const reference of responseReferences(argument)) {
        if (!responseMap.has(reference)) {
          errors.push(`identity.consumer link response file ${reference} is missing its captured contents`);
        }
      }
    }
  }
  return errors;
}

function identityErrors(identity) {
  const errors = [];
  if (!objectLike(identity)) return ["identity must be a JSON object"];
  if (typeof identity.source_commit !== "string" || !/^[a-f0-9]{40}$/.test(identity.source_commit)) {
    errors.push("identity.source_commit must be a 40-character commit SHA");
  }
  if (typeof identity.source_tree !== "string" || !/^[a-f0-9]{40}$/.test(identity.source_tree)) {
    errors.push("identity.source_tree must be a 40-character tree SHA");
  }
  if (!new Set(["archived-head", "worktree-snapshot"]).has(identity.source_snapshot_kind)) {
    errors.push("identity.source_snapshot_kind must identify archived-head or worktree-snapshot");
  }
  if (identity.identity_assurance !== "lineage-and-mismatch-detection; not authentication or attestation") {
    errors.push("identity.identity_assurance must state lineage-only assurance limits");
  }

  errors.push(...outerRunnerErrors(identity.outer_runner));
  if (identity.outer_runner?.kind === "github-actions" &&
      identity.outer_runner.github_actions?.sha !== identity.source_commit) {
    errors.push("identity source commit must match the hosted GITHUB_SHA");
  }
  if (!objectLike(identity.docker_daemon) || !nonEmptyString(identity.docker_daemon.platform)) {
    errors.push("identity.docker_daemon.platform must report the observed daemon platform");
  }
  const container = identity.container;
  if (!objectLike(container)) {
    errors.push("identity.container must be a JSON object");
  } else {
    for (const key of ["os_name", "architecture", "node_version", "node_platform", "node_architecture"]) {
      if (!nonEmptyString(container[key])) errors.push(`identity.container.${key} must be observed`);
    }
    if (!objectLike(container.node_versions) || !nonEmptyString(container.node_versions.modules) ||
        !nonEmptyString(container.node_versions.v8) || !nonEmptyString(container.node_versions.uv)) {
      errors.push("identity.container.node_versions must preserve process.versions runtime details");
    }
  }

  const pkg = identity.package;
  if (!objectLike(pkg)) {
    errors.push("identity.package must be a JSON object");
  } else {
    for (const key of ["target", "core", "core_version", "core_source_revision", "profile",
      "configuration", "libfuturo_build_id"]) {
      if (!nonEmptyString(pkg[key])) errors.push(`identity.package.${key} must be a non-empty string`);
    }
    for (const key of ["api_revision", "abi_revision", "behavior_revision"]) {
      if (!Number.isSafeInteger(pkg[key]) || pkg[key] < 1) {
        errors.push(`identity.package.${key} must be a positive integer`);
      }
    }
    for (const key of ["archive_sha256", "core_archive_sha256"]) {
      if (!sha256(pkg[key])) errors.push(`identity.package.${key} must be a SHA-256 digest`);
    }
  }

  const fixture = identity.fixture_metadata;
  if (!objectLike(fixture)) {
    errors.push("identity.fixture_metadata must be a JSON object");
  } else {
    if (!nonEmptyString(fixture.id)) errors.push("identity.fixture_metadata.id must be a non-empty string");
    if (!Number.isSafeInteger(fixture.bytes) || fixture.bytes < 1) {
      errors.push("identity.fixture_metadata.bytes must be a positive integer");
    }
    if (!sha256(fixture.sha256)) errors.push("identity.fixture_metadata.sha256 must be a SHA-256 digest");
    if (fixture.loaded_or_read !== false) errors.push("identity.fixture_metadata.loaded_or_read must be false");
  }

  const sdk = identity.sdk;
  if (!objectLike(sdk)) {
    errors.push("identity.sdk must be a JSON object");
  } else {
    if (!nonEmptyString(sdk.image) || !/@sha256:[a-f0-9]{64}$/.test(sdk.image)) {
      errors.push("identity.sdk.image must be digest-pinned");
    }
    if (sdk.requested_platform !== "linux/amd64") {
      errors.push("identity.sdk.requested_platform must be linux/amd64");
    }
    if (sdk.resolved_platform !== "linux/amd64") {
      errors.push("identity.sdk.resolved_platform must be linux/amd64");
    }
    if (!nonEmptyString(sdk.container_architecture)) {
      errors.push("identity.sdk.container_architecture must be a non-empty string");
    }
    if (!nonEmptyString(sdk.compiler)) errors.push("identity.sdk.compiler must be a non-empty string");
    if (objectLike(container) && sdk.container_architecture !== container.architecture) {
      errors.push("identity.sdk container architecture must match the observed container architecture");
    }
  }

  const consumer = identity.consumer;
  if (!objectLike(consumer)) {
    errors.push("identity.consumer must be a JSON object");
  } else {
    if (!sha256(consumer.javascript_sha256)) {
      errors.push("identity.consumer.javascript_sha256 must be a SHA-256 digest");
    }
    if (!sha256(consumer.wasm_sha256)) {
      errors.push("identity.consumer.wasm_sha256 must be a SHA-256 digest");
    }
    if (!sha256(consumer.host_controller_sha256)) {
      errors.push("identity.consumer.host_controller_sha256 must be a SHA-256 digest");
    }
    errors.push(...linkCommandErrors(consumer.link_command));
  }

  const browser = identity.browser;
  if (!objectLike(browser)) {
    errors.push("identity.browser must be a JSON object");
  } else {
    if (!nonEmptyString(browser.version)) errors.push("identity.browser.version must be a non-empty string");
    if (!sha256(browser.archive_sha256)) {
      errors.push("identity.browser.archive_sha256 must be a SHA-256 digest");
    }
    if (typeof browser.release_revision !== "string" || !/^\d+$/.test(browser.release_revision)) {
      errors.push("identity.browser.release_revision must be a numeric revision");
    }
    if (browser.requested_platform !== "linux/amd64") {
      errors.push("identity.browser.requested_platform must be linux/amd64");
    }
    if (browser.runtime_packages_classification !== "installed-unpinned") {
      errors.push("identity.browser.runtime_packages_classification must identify an unpinned installed inventory");
    }
    if (!Array.isArray(browser.runtime_packages) || browser.runtime_packages.length === 0 ||
        browser.runtime_packages.some(item => !nonEmptyString(item) || !/^[^=]+=.+$/.test(item))) {
      errors.push("identity.browser.runtime_packages must contain the resolved package=version inventory");
    }
  }
  return errors;
}

function scenarioEvidenceErrors(scenario, browserReport) {
  const errors = [];
  const expectedKeys = SCENARIO_EVIDENCE_KEY[scenario];
  const evidence = browserReport.scenarios;
  if (!objectLike(evidence)) return ["browser report scenarios must be a JSON object"];
  for (const key of expectedKeys) {
    const value = evidence[key];
    if (!objectLike(value) || value.result !== "pass") {
      errors.push(`browser report positive CDP evidence is missing scenarios.${key}.result=pass`);
    }
  }

  if (scenario === "identity") {
    const positive = evidence.positive;
    const mismatch = evidence.mismatch;
    if (positive?.instance_created !== true || positive?.instance_destroyed !== true ||
        positive?.load_called !== false) {
      errors.push("identity positive CDP evidence lacks create/destroy/no-load assertions");
    }
    if (!Number.isSafeInteger(mismatch?.status) || mismatch.status === 0 ||
        mismatch?.load_called !== false || mismatch?.content_accessed !== false) {
      errors.push("identity mismatch CDP evidence lacks refusal-before-content assertions");
    }
  } else if (scenario === "host-tracer") {
    const tracer = evidence.tracer;
    if (tracer?.raw_index_oracle !== "pass" || tracer?.canvas_oracle !== "pass" ||
        tracer?.changed_pixel_control !== "rejected" || tracer?.start_trusted !== true ||
        tracer?.user_activation !== true || !Number.isFinite(tracer?.audio_graph_rms) ||
        tracer.audio_graph_rms <= 0 || tracer?.progress !== 2 ||
        tracer?.frame_progress !== 2 || tracer?.input_buttons !== 0) {
      errors.push("host-tracer CDP evidence lacks independent frame/audio, trusted-input, or progress checks");
    }
  } else if (scenario === "host-content") {
    const content = evidence.content;
    if (content?.valid_retry !== true || content?.valid_retry_frame_oracle !== true ||
        content?.valid_retry_frame_progress !== 2 || content?.valid_retry_input_buttons !== 0 ||
        content?.privacy_clean !== true || content?.start_trusted !== true ||
        content?.user_activation !== true) {
      errors.push("host-content CDP evidence lacks retry, frame, privacy, or trusted-input checks");
    }
  } else if (scenario === "host-input") {
    const input = evidence.input;
    if (input?.all_five_bits !== true || input?.combined_input !== true ||
        input?.repeat_ignored !== true || input?.keyup_release !== true ||
        input?.focus_loss_clear !== true || input?.hidden_clear !== true) {
      errors.push("host-input CDP evidence lacks trusted-key and input-release checks");
    }
  } else if (scenario === "host-input-audio") {
    const audio = evidence.audio;
    if (audio?.trusted_start !== true || audio?.user_activation !== true ||
        audio?.oracle_pcm_validation !== true || audio?.changed_sample_control_rejected !== true ||
        audio?.queue_bounded !== true || audio?.suspension_paused !== true ||
        audio?.no_auto_resume !== true) {
      errors.push("host-input-audio CDP evidence lacks trusted PCM and interruption checks");
    }
  } else if (scenario === "host-lifecycle") {
    const lifecycle = evidence.lifecycle;
    if (lifecycle?.stop_destroys_once !== true || lifecycle?.stale_callback_no_calls !== true ||
        lifecycle?.pagehide_paused !== true || lifecycle?.pagehide_input_cleared !== true ||
        lifecycle?.pagehide_audio_discarded !== true ||
        lifecycle?.audio_retirement?.queued_before_hide !== true ||
        lifecycle?.audio_retirement?.source_retired_on_hide !== true ||
        !Number.isSafeInteger(lifecycle?.audio_retirement?.queue_samples_before_hide) ||
        lifecycle.audio_retirement.queue_samples_before_hide < 1 ||
        !Number.isSafeInteger(lifecycle?.audio_retirement?.sources_stopped_after_hide) ||
        lifecycle.audio_retirement.sources_stopped_after_hide <= lifecycle.audio_retirement.sources_stopped_before_hide) {
      errors.push("host-lifecycle CDP evidence lacks audio retirement, pagehide cleanup, or exactly-once teardown checks");
    }
  } else if (scenario === "host-ui") {
    const ui = evidence.ui;
    if (ui?.runtime_error_state !== true || ui?.stopped_state !== true ||
        ui?.keyboard_focus !== true || ui?.semantic_contract !== true) {
      errors.push("host-ui CDP evidence lacks runtime-error, stop, keyboard, or semantic checks");
    }
  }
  return errors;
}

function safeReportReference(reference, scenario) {
  if (typeof reference !== "string" || reference.includes("\\") || path.posix.isAbsolute(reference)) {
    return false;
  }
  const parts = reference.split("/");
  return parts.length === 4 && parts[0] === "qualification" && parts[1] === "scenarios" &&
    parts[2] === scenario && parts[3] === "browser-report.json" &&
    !parts.some(part => part === "" || part === "." || part === "..");
}

function readScenarioReport(baseDirectory, reference) {
  const base = realpathSync(baseDirectory);
  const candidate = path.resolve(base, ...reference.split("/"));
  const relative = path.relative(base, candidate);
  if (relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) {
    throw new Error("browser report path escapes the evidence directory");
  }
  const realCandidate = realpathSync(candidate);
  const realRelative = path.relative(base, realCandidate);
  if (realRelative.startsWith(`..${path.sep}`) || realRelative === ".." || path.isAbsolute(realRelative)) {
    throw new Error("browser report resolves outside the evidence directory");
  }
  if (!lstatSync(realCandidate).isFile()) throw new Error("browser report is not a regular file");
  return JSON.parse(readFileSync(realCandidate, "utf8"));
}

function embeddedScenarioReport(browserReport) {
  const project = (value, fields) => {
    if (!objectLike(value)) return value;
    return Object.fromEntries(fields.filter(key => Object.hasOwn(value, key)).map(key => [key, value[key]]));
  };
  const projectArray = (value, fields) => Array.isArray(value)
    ? value.map(item => project(item, fields))
    : value;
  const input = project(browserReport.input, [
    "source_snapshot_kind", "source_commit", "source_tree", "target", "core", "core_version",
    "core_source_revision", "package_build_id", "package_archive_sha256", "core_archive_sha256",
    "profile", "configuration", "api_revision", "abi_revision", "behavior_revision",
    "fixture_metadata", "javascript_sha256", "host_controller_sha256", "wasm_sha256", "link_command",
  ]);
  if (objectLike(input)) {
    input.fixture_metadata = project(input.fixture_metadata, ["id", "bytes", "sha256", "loaded_or_read"]);
    input.link_command = project(input.link_command, [
      "command_text", "command_sha256", "normalized_command", "normalized_command_sha256",
      "normalizations", "command_arguments", "ordered_arguments", "response_files",
    ]);
    if (objectLike(input.link_command)) {
      input.link_command.normalizations = projectArray(input.link_command.normalizations, ["source_path", "token"]);
      input.link_command.response_files = projectArray(input.link_command.response_files,
        ["reference", "path", "contents", "sha256"]);
    }
  }
  const browser = project(browserReport.browser, [
    "version_expected", "binary_version", "archive_sha256", "archive_sha256_expected", "release_revision",
    "requested_platform", "container_architecture", "runtime_packages_classification", "runtime_packages",
  ]);
  const outerRunner = project(browserReport.outer_runner, [
    "kind", "os", "architecture", "runner_name", "image_version", "github_actions",
  ]);
  if (objectLike(outerRunner)) {
    outerRunner.runner_name = project(outerRunner.runner_name, ["applicability", "value"]);
    outerRunner.image_version = project(outerRunner.image_version, ["applicability", "value"]);
    outerRunner.github_actions = project(outerRunner.github_actions,
      ["applicability", "sha", "run_id", "run_attempt", "workflow", "job", "event_name"]);
  }
  const container = project(browserReport.container, [
    "os_name", "architecture", "node_version", "node_platform", "node_architecture", "node_versions",
  ]);
  if (objectLike(container)) {
    // This is the explicit process.versions field, not an environment dump; keep it whole so identity stays exact across Node patch releases.
    if (objectLike(container.node_versions)) container.node_versions = { ...container.node_versions };
  }

  const scenarioSlots = {
    identity: ["positive", "mismatch"], "host-tracer": ["tracer"], "host-content": ["content"],
    "host-input": ["input"], "host-input-audio": ["audio"], "host-lifecycle": ["lifecycle"],
    "host-ui": ["ui"],
  };
  const evidenceFields = {
    positive: ["result", "instance_created", "instance_destroyed", "load_called"],
    mismatch: ["result", "status", "load_called", "content_accessed"],
    tracer: ["result", "raw_index_oracle", "canvas_oracle", "changed_pixel_control", "start_trusted",
      "user_activation", "audio_graph_rms", "progress", "frame_progress", "input_buttons"],
    content: ["result", "valid_retry", "valid_retry_frame_oracle", "valid_retry_frame_progress",
      "valid_retry_input_buttons", "privacy_clean", "start_trusted", "user_activation"],
    input: ["result", "all_five_bits", "combined_input", "repeat_ignored", "keyup_release",
      "focus_loss_clear", "hidden_clear"],
    audio: ["result", "trusted_start", "user_activation", "oracle_pcm_validation",
      "changed_sample_control_rejected", "queue_bounded", "suspension_paused", "no_auto_resume"],
    lifecycle: ["result", "stop_destroys_once", "stale_callback_no_calls", "pagehide_paused",
      "pagehide_input_cleared", "pagehide_audio_discarded", "audio_retirement"],
    ui: ["result", "runtime_error_state", "stopped_state", "keyboard_focus", "semantic_contract"],
  };
  const scenarios = browserReport.scenarios;
  let sanitizedScenarios = scenarios;
  if (objectLike(scenarios)) {
    sanitizedScenarios = {};
    for (const scenario of SCENARIO_INVENTORY) {
      for (const slot of scenarioSlots[scenario]) {
        if (!Object.hasOwn(scenarios, slot)) continue;
        sanitizedScenarios[slot] = project(scenarios[slot], evidenceFields[slot]);
        if (slot === "lifecycle" && objectLike(sanitizedScenarios[slot])) {
          sanitizedScenarios[slot].audio_retirement = project(
            sanitizedScenarios[slot].audio_retirement,
            ["queued_before_hide", "queue_frames_before_hide", "queue_samples_before_hide",
              "sources_stopped_before_hide", "sources_stopped_after_hide", "source_retired_on_hide"],
          );
        }
      }
    }
  }
  const safeReport = {
    schema_version: browserReport.schema_version,
    status: browserReport.status,
    sdk: project(browserReport.sdk, ["image", "requested_platform", "resolved_platform", "container_architecture", "compiler"]),
    source_tree: browserReport.source_tree,
    outer_runner: outerRunner,
    docker_daemon: project(browserReport.docker_daemon, ["platform"]),
    container,
    identity_assurance: browserReport.identity_assurance,
    browser,
    input,
    qualification: project(browserReport.qualification, ["run_id", "scenario", "attempt", "generated_at"]),
    scenarios: sanitizedScenarios,
  };
  return Object.fromEntries(Object.keys(safeReport)
    .filter(key => Object.hasOwn(browserReport, key)).map(key => [key, safeReport[key]]));
}

function reportIdentityErrors(identity, browserReport) {
  const input = browserReport.input;
  const sdk = browserReport.sdk;
  const browser = browserReport.browser;
  if (!objectLike(input)) return ["browser report input identity is missing"];
  if (!objectLike(sdk)) return ["browser report SDK identity is missing"];
  if (!objectLike(browser)) return ["browser report browser identity is missing"];
  if (browserReport.identity_assurance !== identity.identity_assurance) {
    return ["browser report identity assurance does not match suite identity"];
  }
  const expectedPackage = identity.package;
  const checks = [
    [browserReport.source_tree, identity.source_tree, "source tree"],
    [browserReport.outer_runner, identity.outer_runner, "outer runner"],
    [browserReport.docker_daemon, identity.docker_daemon, "Docker daemon"],
    [browserReport.container, identity.container, "SDK container"],
    [input.source_snapshot_kind, identity.source_snapshot_kind, "source snapshot kind"],
    [input.source_commit, identity.source_commit, "source commit"],
    [input.source_tree, identity.source_tree, "source tree"],
    [input.target, expectedPackage.target, "package target"],
    [input.core, expectedPackage.core, "core name"],
    [input.core_version, expectedPackage.core_version, "core version"],
    [input.core_source_revision, expectedPackage.core_source_revision, "core source revision"],
    [input.package_build_id, expectedPackage.libfuturo_build_id, "package build ID"],
    [input.package_archive_sha256, expectedPackage.archive_sha256, "package archive digest"],
    [input.core_archive_sha256, expectedPackage.core_archive_sha256, "core archive digest"],
    [input.profile, expectedPackage.profile, "profile"],
    [input.configuration, expectedPackage.configuration, "configuration"],
    [input.api_revision, expectedPackage.api_revision, "API revision"],
    [input.abi_revision, expectedPackage.abi_revision, "ABI revision"],
    [input.behavior_revision, expectedPackage.behavior_revision, "behavior revision"],
    [input.fixture_metadata, identity.fixture_metadata, "fixture identity"],
    [input.javascript_sha256, identity.consumer.javascript_sha256, "consumer JavaScript digest"],
    [input.host_controller_sha256, identity.consumer.host_controller_sha256, "host controller digest"],
    [input.wasm_sha256, identity.consumer.wasm_sha256, "consumer Wasm digest"],
    [input.link_command, identity.consumer.link_command, "generated link command"],
    [sdk.image, identity.sdk.image, "SDK image"],
    [sdk.requested_platform, identity.sdk.requested_platform, "SDK platform"],
    [sdk.resolved_platform, identity.sdk.resolved_platform, "resolved SDK platform"],
    [sdk.container_architecture, identity.sdk.container_architecture, "SDK container architecture"],
    [sdk.compiler, identity.sdk.compiler, "SDK compiler"],
    [browser.runtime_packages_classification, identity.browser.runtime_packages_classification, "runtime package classification"],
    [browser.runtime_packages, identity.browser.runtime_packages, "runtime package inventory"],
    [browser.version_expected, identity.browser.version, "browser expected version"],
    [browser.archive_sha256, identity.browser.archive_sha256, "browser archive digest"],
    [browser.archive_sha256_expected, identity.browser.archive_sha256, "expected browser archive digest"],
    [browser.release_revision, identity.browser.release_revision, "browser release revision"],
    [browser.requested_platform, identity.browser.requested_platform, "browser platform"],
    [browser.container_architecture, identity.sdk.container_architecture, "browser container architecture"],
  ];
  const errors = [];
  for (const [actual, expected, label] of checks) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) errors.push(`browser report ${label} does not match suite identity`);
  }
  if (typeof browser.binary_version !== "string" ||
      !browser.binary_version.includes(identity.browser.version)) {
    errors.push("browser report binary version does not match suite identity");
  }
  return errors;
}

function timingErrors(timings, { allowProvisional = false, results = [] } = {}) {
  const errors = [];
  if (!objectLike(timings)) return ["timings must be a JSON object"];
  if (timings.schema_version !== 1) errors.push("timings schema_version is unsupported");
  if (allowProvisional ? timings.finalized !== false : timings.finalized !== true) {
    errors.push(`timings finalized must be ${allowProvisional ? "false for internal provisional validation" : "true"}`);
  }
  for (const [domain, description] of Object.entries(TIMING_CLOCK_DOMAINS)) {
    if (timings.clock_domains?.[domain] !== description) {
      errors.push(`timings clock_domains.${domain} does not match the declared monotonic clock`);
    }
  }
  for (const [stage, domain] of Object.entries(TIMING_STAGE_DOMAINS)) {
    if (timings.stage_clock_domains?.[stage] !== domain) {
      errors.push(`timings stage_clock_domains.${stage} does not match its declared domain`);
    }
  }
  if (!objectLike(timings.clock_domains) ||
      Object.keys(timings.clock_domains).length !== Object.keys(TIMING_CLOCK_DOMAINS).length) {
    errors.push("timings clock_domains has missing or unexpected fields");
  }
  if (!objectLike(timings.stage_clock_domains) ||
      Object.keys(timings.stage_clock_domains).length !== Object.keys(TIMING_STAGE_DOMAINS).length) {
    errors.push("timings stage_clock_domains has missing or unexpected fields");
  }

  const durations = timings.durations_seconds;
  if (!objectLike(durations)) return [...errors, "timings durations_seconds must be a JSON object"];
  const required = [
    "outer_setup_image_acquisition", "package_configure", "package_build",
    "package_install_relocation", "consumer_configure", "consumer_build",
    "browser_setup", "scenario_execution", "docker_run", "total",
  ];
  const provisionalNulls = new Set(["docker_run", "total"]);
  for (const name of required) {
    const value = durations[name];
    const provisional = allowProvisional && provisionalNulls.has(name) && value === null;
    if (!provisional && (!Number.isFinite(value) || value < 0)) {
      errors.push(`timings ${name} duration must be a finite non-negative number`);
    }
  }
  if (!objectLike(durations.scenarios)) {
    errors.push("timings scenarios duration map is missing");
  } else {
    const names = Object.keys(durations.scenarios);
    if (JSON.stringify(names) !== JSON.stringify(SCENARIO_INVENTORY)) {
      errors.push("timings scenario durations do not match the required ordered inventory");
    }
    for (const scenario of SCENARIO_INVENTORY) {
      const duration = durations.scenarios[scenario];
      if (!Number.isFinite(duration) || duration < 0) {
        errors.push(`timings ${scenario} duration must be a finite non-negative number`);
      }
      const result = results.find(item => item?.scenario === scenario);
      if (result && Number.isFinite(duration) && Number.isFinite(result.elapsed_seconds) &&
          Math.abs(duration - result.elapsed_seconds) > 0.005) {
        errors.push(`timings ${scenario} duration does not match its scenario result`);
      }
    }
    const scenarioTotal = Object.values(durations.scenarios).every(Number.isFinite)
      ? Object.values(durations.scenarios).reduce((sum, value) => sum + value, 0)
      : null;
    if (scenarioTotal !== null && Number.isFinite(durations.scenario_execution) &&
        Math.abs(scenarioTotal - durations.scenario_execution) > 0.002) {
      errors.push("timings scenario_execution does not equal the sum of scenario durations");
    }
  }

  const intervals = timings.intervals;
  if (!objectLike(intervals)) {
    errors.push("timings intervals must preserve the observed stage boundaries");
  } else {
    const intervalSpecs = [
      ["outer_setup_image_acquisition", "nanoseconds"],
      ["docker_run", "nanoseconds"], ["total", "nanoseconds"],
      ["package_configure", "nanoseconds"], ["package_build", "nanoseconds"],
      ["package_install_relocation", "nanoseconds"], ["consumer_configure", "nanoseconds"],
      ["consumer_build", "nanoseconds"], ["browser_setup", "nanoseconds"],
    ];
    for (const [name, unit] of intervalSpecs) {
      const interval = intervals[name];
      const provisional = allowProvisional && provisionalNulls.has(name) && interval === null;
      if (provisional) continue;
      if (!objectLike(interval) || interval.unit !== unit ||
          !Number.isFinite(interval.start) || interval.start < 0 ||
          !Number.isFinite(interval.end) || interval.end < interval.start) {
        errors.push(`timings ${name} boundary interval is missing or invalid`);
        continue;
      }
      const seconds = (interval.end - interval.start) / (unit === "nanoseconds" ? 1e9 : 1e3);
      if (Number.isFinite(durations[name]) && Math.abs(seconds - durations[name]) > 0.002) {
        errors.push(`timings ${name} duration contradicts its boundaries`);
      }
    }
    const scenarioIntervals = intervals.scenarios;
    if (!objectLike(scenarioIntervals) ||
        JSON.stringify(Object.keys(scenarioIntervals)) !== JSON.stringify(SCENARIO_INVENTORY)) {
      errors.push("timings scenario boundary map is missing or incomplete");
    } else {
      let previousEnd = -Infinity;
      for (const scenario of SCENARIO_INVENTORY) {
        const interval = scenarioIntervals[scenario];
        if (!objectLike(interval) || interval.unit !== "milliseconds" ||
            !Number.isFinite(interval.start) || interval.start < 0 ||
            !Number.isFinite(interval.end) || interval.end < interval.start) {
          errors.push(`timings ${scenario} boundary interval is missing or invalid`);
          continue;
        }
        if (interval.start < previousEnd) errors.push(`timings ${scenario} boundary overlaps the prior serial scenario`);
        previousEnd = interval.end;
        const seconds = (interval.end - interval.start) / 1000;
        if (Number.isFinite(durations.scenarios?.[scenario]) &&
            Math.abs(seconds - durations.scenarios[scenario]) > 0.002) {
          errors.push(`timings ${scenario} duration contradicts its boundaries`);
        }
      }
    }
  }

  if (durations.scenario_execution !== null &&
      Number.isFinite(durations.scenario_execution)) {
    const nestedStages = required.filter(name => !["outer_setup_image_acquisition", "docker_run", "total"].includes(name));
    const nestedDuration = nestedStages.reduce((sum, name) =>
      sum + (Number.isFinite(durations[name]) ? durations[name] : 0), 0);
    if (Number.isFinite(durations.docker_run) && nestedDuration > durations.docker_run + 0.1) {
      errors.push("timings nested container/scenario stages exceed docker_run");
    }
  }
  if (Number.isFinite(durations.total) && Number.isFinite(durations.outer_setup_image_acquisition) &&
      durations.total + 0.002 < durations.outer_setup_image_acquisition) {
    errors.push("timings total is shorter than outer setup/image acquisition");
  }
  if (Number.isFinite(durations.total) && Number.isFinite(durations.docker_run) &&
      Number.isFinite(durations.outer_setup_image_acquisition) &&
      Math.abs(durations.total - durations.outer_setup_image_acquisition - durations.docker_run) > 0.002) {
    errors.push("timings docker_run and outer setup do not add to total");
  }

  if (JSON.stringify(timings.nesting) !== JSON.stringify(TIMING_NESTING)) {
    errors.push("timings nesting contract is missing or contradictory");
  }
  if (!objectLike(timings.queue) || timings.queue.status !== "not-available-locally" ||
      timings.queue.seconds !== null ||
      timings.queue.source !== "hosted GitHub Actions run/job records only (Plan 03-05)") {
    errors.push("timings queue must remain unavailable locally until hosted run/job records exist");
  }
  const cache = timings.cache_observations;
  if (!objectLike(cache) || !["verified-hit", "miss"].includes(cache.sdk_image) ||
      !["verified-hit", "downloaded"].includes(cache.browser_archive) ||
      cache.apt_packages !== "not-claimed-unverified") {
    errors.push("timings cache observations must reflect only the existing digest-verified image/archive caches");
  }
  return errors;
}

export function validateAggregate(aggregate, {
  baseDirectory = process.cwd(),
  allowProvisionalTimings = false,
  requireEmbeddedScenarioReports = false,
} = {}) {
  const errors = [];
  if (!objectLike(aggregate)) return { valid: false, errors: ["aggregate must be a JSON object"] };
  if (aggregate.schema_version !== REPORT_SCHEMA_VERSION) errors.push("schema_version is unsupported");
  if (aggregate.status !== "qualification-pass") errors.push("aggregate status is not qualification-pass");
  if (typeof aggregate.run_id !== "string" ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]{5,127}$/.test(aggregate.run_id)) {
    errors.push("run_id is missing or malformed");
  }
  if (!isoTime(aggregate.started_at) || !isoTime(aggregate.completed_at) ||
      Date.parse(aggregate.completed_at) < Date.parse(aggregate.started_at)) {
    errors.push("aggregate start/completion timestamps are missing or inconsistent");
  }
  const aggregateIdentityErrors = identityErrors(aggregate.identity);
  errors.push(...aggregateIdentityErrors);
  errors.push(...timingErrors(aggregate.timings, {
    allowProvisional: allowProvisionalTimings,
    results: Array.isArray(aggregate.results) ? aggregate.results : [],
  }));
  if (!Array.isArray(aggregate.scenario_inventory) ||
      JSON.stringify(aggregate.scenario_inventory) !== JSON.stringify(SCENARIO_INVENTORY)) {
    errors.push("scenario_inventory does not exactly match the required ordered inventory");
  }
  if (!Array.isArray(aggregate.results)) {
    errors.push("results must be an array");
    return { valid: false, errors };
  }

  const hasEmbeddedScenarioReports = Object.hasOwn(aggregate, "scenario_reports");
  const embeddedReports = aggregate.scenario_reports;
  if (requireEmbeddedScenarioReports && !hasEmbeddedScenarioReports) {
    errors.push("scenario_reports are required for self-contained hosted evidence");
  }
  if (hasEmbeddedScenarioReports && (!objectLike(embeddedReports) ||
      JSON.stringify(Object.keys(embeddedReports)) !== JSON.stringify(SCENARIO_INVENTORY))) {
    errors.push("scenario_reports must contain exactly the required ordered seven-scenario inventory");
  }

  const seen = new Set();
  for (const result of aggregate.results) {
    if (!objectLike(result)) {
      errors.push("scenario result must be a JSON object");
      continue;
    }
    if (!nonEmptyString(result.scenario)) {
      errors.push("scenario result name is missing or has the wrong type");
      continue;
    }
    const scenario = result.scenario;
    if (!SCENARIO_INVENTORY.includes(scenario)) {
      errors.push(`unknown scenario result: ${scenario}`);
      continue;
    }
    if (seen.has(scenario)) {
      errors.push(`duplicate scenario result: ${scenario}`);
      continue;
    }
    seen.add(scenario);
  }
  for (const scenario of SCENARIO_INVENTORY) {
    if (!seen.has(scenario)) errors.push(`missing scenario result: ${scenario}`);
  }
  if (aggregate.results.length !== SCENARIO_INVENTORY.length) {
    errors.push("results must contain exactly seven scenario entries");
  }

  for (const result of aggregate.results) {
    if (!objectLike(result) || !SCENARIO_INVENTORY.includes(result.scenario)) continue;
    const scenario = result.scenario;
    if (result.status !== "pass") errors.push(`${scenario} result status is not pass`);
    if (result.run_id !== aggregate.run_id) errors.push(`${scenario} run_id does not match aggregate`);
    if (result.attempt !== 1) errors.push(`${scenario} attempt must equal one`);
    if (!Array.isArray(result.retry_history) || result.retry_history.length !== 0) {
      errors.push(`${scenario} retry_history must be an empty array`);
    }
    if (!objectLike(result.child)) {
      errors.push(`${scenario} child facts are missing`);
    } else {
      if (result.child.exit_code !== 0) errors.push(`${scenario} child exit_code must equal zero`);
      if (result.child.signal !== null) errors.push(`${scenario} child signal must be null`);
      if (result.child.timed_out !== false) errors.push(`${scenario} child timed_out must be false`);
      if (result.child.cancelled !== false) errors.push(`${scenario} child cancelled must be false`);
    }
    if (!isoTime(result.started_at) || !isoTime(result.completed_at) ||
        Date.parse(result.completed_at) < Date.parse(result.started_at) ||
        (isoTime(aggregate.started_at) && Date.parse(result.started_at) < Date.parse(aggregate.started_at)) ||
        (isoTime(aggregate.completed_at) && Date.parse(result.completed_at) > Date.parse(aggregate.completed_at))) {
      errors.push(`${scenario} timestamps are missing or outside the aggregate run`);
    }
    if (!Number.isFinite(result.elapsed_seconds) || result.elapsed_seconds < 0) {
      errors.push(`${scenario} elapsed_seconds must be a non-negative number`);
    }
    if (!safeReportReference(result.browser_report, scenario)) {
      errors.push(`${scenario} browser report reference is unsafe or does not identify its own report`);
      continue;
    }

    let browserReport;
    if (requireEmbeddedScenarioReports) {
      browserReport = embeddedReports?.[scenario];
      if (!objectLike(browserReport)) {
        errors.push(`${scenario} embedded browser report is missing or malformed`);
        continue;
      }
    } else {
      try {
        browserReport = readScenarioReport(baseDirectory, result.browser_report);
      } catch (error) {
        errors.push(`${scenario} browser report could not be read: ${error.message}`);
        continue;
      }
    }
    const runMetadata = browserReport.qualification;
    if (!objectLike(runMetadata) || runMetadata.run_id !== aggregate.run_id ||
        runMetadata.scenario !== scenario || runMetadata.attempt !== 1 ||
        !isoTime(runMetadata.generated_at) ||
        Date.parse(runMetadata.generated_at) < Date.parse(result.started_at ?? "invalid") ||
        Date.parse(runMetadata.generated_at) > Date.parse(result.completed_at ?? "invalid")) {
      errors.push(`${scenario} browser report is stale or has mismatched run/scenario/attempt metadata`);
    }
    if (browserReport.status !== "browser-pass") {
      errors.push(`${scenario} browser report status conflicts with a passing child result`);
    }
    if (browserReport.schema_version !== REPORT_SCHEMA_VERSION) {
      errors.push(`${scenario} browser report schema_version is unsupported`);
    }
    if (aggregateIdentityErrors.length === 0) {
      errors.push(...reportIdentityErrors(aggregate.identity, browserReport));
    }
    errors.push(...scenarioEvidenceErrors(scenario, browserReport));
  }

  return { valid: errors.length === 0, errors };
}

function relativeEvidencePath(reportPath, absolutePath) {
  return path.relative(path.dirname(reportPath), absolutePath).split(path.sep).join("/");
}

function aggregateTimingEvidence(consumerTimings, results, scenarioIntervals) {
  const timings = clone(consumerTimings);
  const durations = { ...timings.durations_seconds };
  const scenarioDurations = Object.fromEntries(results.map(result => [result.scenario, result.elapsed_seconds]));
  const completeScenarioDurations = SCENARIO_INVENTORY.every(name => Number.isFinite(scenarioDurations[name]));
  durations.scenarios = scenarioDurations;
  durations.scenario_execution = completeScenarioDurations
    ? Object.values(scenarioDurations).reduce((sum, value) => sum + value, 0)
    : null;
  durations.docker_run = null;
  durations.total = null;
  const intervals = { ...timings.intervals, scenarios: scenarioIntervals, docker_run: null, total: null };
  return {
    ...timings,
    finalized: false,
    durations_seconds: durations,
    intervals,
    clock_domains: clone(TIMING_CLOCK_DOMAINS),
    stage_clock_domains: clone(TIMING_STAGE_DOMAINS),
    nesting: clone(TIMING_NESTING),
  };
}

export function finalizeAggregateTimings(reportPath, outerStartNs, outerSetupEndNs, outerEndNs, consumerReportPath = null) {
  const values = [outerStartNs, outerSetupEndNs, outerEndNs].map(Number);
  if (values.some(value => !Number.isFinite(value) || value < 0) ||
      values[1] < values[0] || values[2] < values[1]) {
    throw new Error("outer monotonic timing boundaries are invalid");
  }
  const [start, setupEnd, end] = values;
  const aggregate = JSON.parse(readFileSync(reportPath, "utf8"));
  if (!objectLike(aggregate.timings) || aggregate.status !== "qualification-finalizing") {
    throw new Error("only a validated provisional aggregate can be finalized");
  }
  aggregate.status = "qualification-pass";
  aggregate.timings.finalized = true;
  aggregate.timings.durations_seconds.outer_setup_image_acquisition = (setupEnd - start) / 1e9;
  aggregate.timings.durations_seconds.docker_run = (end - setupEnd) / 1e9;
  aggregate.timings.durations_seconds.total = (end - start) / 1e9;
  aggregate.timings.intervals.outer_setup_image_acquisition = {
    start, end: setupEnd, unit: "nanoseconds",
  };
  aggregate.timings.intervals.docker_run = {
    start: setupEnd, end, unit: "nanoseconds",
  };
  aggregate.timings.intervals.total = { start, end, unit: "nanoseconds" };
  const validation = validateAggregate(aggregate, { baseDirectory: path.dirname(reportPath) });
  if (!validation.valid) {
    throw new Error(`final timing validation failed: ${validation.errors.join("; ")}`);
  }
  if (consumerReportPath && existsSync(consumerReportPath)) {
    const consumerReport = JSON.parse(readFileSync(consumerReportPath, "utf8"));
    if (consumerReport.browser?.status !== "qualification-finalizing") {
      throw new Error("consumer report is not awaiting final qualification timing");
    }
    consumerReport.browser.status = "qualification-pass";
    consumerReport.browser.elapsed_seconds = aggregate.elapsed_seconds;
    atomicWriteJson(consumerReportPath, consumerReport);
  }
  atomicWriteJson(reportPath, aggregate);
  return aggregate;
}

function atomicWriteJson(filePath, value) {
  const directory = path.dirname(filePath);
  mkdirSync(directory, { recursive: true });
  const temporaryPath = `${filePath}.tmp-${process.pid}-${randomBytes(6).toString("hex")}`;
  const descriptor = openSync(temporaryPath, "wx", 0o600);
  try {
    writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  } finally {
    closeSync(descriptor);
  }
  renameSync(temporaryPath, filePath);
}

function cleanMessage(value) {
  return String(value ?? "unknown failure")
    .replace(/(?:https?|file):\/\/[^\s)]+/g, "[url]")
    .replace(/\/(?:work|tmp|private|Users)\/[^\s)]+/g, "[path]")
    .slice(0, 320);
}

function createInitialResult(scenario, runId, reportPath, evidenceDirectory) {
  const scenarioDirectory = path.join(evidenceDirectory, "scenarios", scenario);
  return {
    scenario,
    status: "not-run",
    run_id: runId,
    attempt: 1,
    retry_history: [],
    child: { exit_code: null, signal: null, timed_out: false, cancelled: false },
    browser_report: relativeEvidencePath(reportPath,
      path.join(scenarioDirectory, "browser-report.json")),
    logs: {
      stdout: relativeEvidencePath(reportPath, path.join(scenarioDirectory, "runner.stdout.log")),
      stderr: relativeEvidencePath(reportPath, path.join(scenarioDirectory, "runner.stderr.log")),
      browser: relativeEvidencePath(reportPath, path.join(scenarioDirectory, "browser-process.log")),
    },
    started_at: null,
    completed_at: null,
    elapsed_seconds: null,
  };
}

function finishWriteStreams(streams) {
  return Promise.all(streams.map(stream => new Promise(resolve => {
    if (stream.closed || stream.destroyed) return resolve();
    stream.end(resolve);
  })));
}

export async function runBrowserChild(spec, { signal, timeoutMs = CHILD_TIMEOUT_MS } = {}) {
  const stdoutStream = createWriteStream(spec.stdoutPath, { flags: "wx", mode: 0o600 });
  const stderrStream = createWriteStream(spec.stderrPath, { flags: "wx", mode: 0o600 });
  let child;
  try {
    child = spawn(spec.executable, spec.args, {
      env: spec.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    await finishWriteStreams([stdoutStream, stderrStream]);
    return { exitCode: null, signal: null, timedOut: false, cancelled: false, spawnError: cleanMessage(error.message) };
  }
  child.stdout.pipe(stdoutStream);
  child.stderr.pipe(stderrStream);

  return new Promise(resolve => {
    let settled = false;
    let timedOut = false;
    let cancelled = false;
    let spawnError = null;
    let escalationTimer = null;
    let cleanupTimer = null;
    const finish = async (exitCode, exitSignal, cleanupTimedOut = false) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutTimer);
      clearTimeout(escalationTimer);
      clearTimeout(cleanupTimer);
      signal?.removeEventListener("abort", abortChild);
      await finishWriteStreams([stdoutStream, stderrStream]);
      resolve({
        exitCode,
        signal: exitSignal ?? null,
        timedOut,
        cancelled,
        cleanupTimedOut,
        ...(spawnError ? { spawnError } : {}),
      });
    };
    const requestStop = kind => {
      if (kind === "timeout") timedOut = true;
      if (kind === "cancel") cancelled = true;
      if (child.exitCode !== null || child.signalCode !== null) return;
      try { child.kill("SIGTERM"); } catch { /* close/error handlers provide the final child facts */ }
      escalationTimer = setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null) {
          try { child.kill("SIGKILL"); } catch { /* final bounded cleanup below */ }
        }
      }, CHILD_KILL_GRACE_MS);
      cleanupTimer = setTimeout(() => {
        child.unref?.();
        void finish(child.exitCode, child.signalCode ?? (timedOut ? "SIGKILL" : "SIGTERM"), true);
      }, CHILD_CLEANUP_LIMIT_MS);
    };
    const abortChild = () => requestStop("cancel");
    const timeoutTimer = setTimeout(() => requestStop("timeout"), timeoutMs);
    child.once("error", error => { spawnError = cleanMessage(error.message); });
    child.once("close", (code, childSignal) => { void finish(code, childSignal); });
    if (signal?.aborted) abortChild();
    else signal?.addEventListener("abort", abortChild, { once: true });
  });
}

function attachQualificationMetadata(report, result, runId, generatedAt) {
  report.qualification = {
    run_id: runId,
    scenario: result.scenario,
    attempt: result.attempt,
    generated_at: generatedAt,
  };
  return report;
}

function printAggregate(report) {
  process.stdout.write("=== LIBFUTURO_BROWSER_QUALIFICATION_BEGIN ===\n");
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write("=== LIBFUTURO_BROWSER_QUALIFICATION_END ===\n");
}

function printFinalAggregate(report) {
  process.stdout.write("=== LIBFUTURO_BROWSER_QUALIFICATION_FINAL_BEGIN ===\n");
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write("=== LIBFUTURO_BROWSER_QUALIFICATION_FINAL_END ===\n");
}

export async function runQualification({
  reportPath,
  evidenceDirectory,
  consumerReport,
  consumerReportPath,
  cdpScriptPath,
  env = process.env,
  runId = `${Date.now()}-${process.pid}-${randomBytes(5).toString("hex")}`,
  spawnScenario = runBrowserChild,
  signal,
  timeoutMs = CHILD_TIMEOUT_MS,
  now = () => new Date(),
  monotonicNow = () => performance.now(),
  emit = () => {},
} = {}) {
  if (!nonEmptyString(reportPath) || !nonEmptyString(evidenceDirectory)) {
    throw new Error("qualification report and evidence paths are required");
  }
  if (existsSync(reportPath)) throw new Error("qualification report path already exists; refusing stale report reuse");
  if (existsSync(evidenceDirectory)) {
    throw new Error("qualification evidence directory already exists; refusing stale scenario evidence reuse");
  }
  if (!objectLike(consumerReport) || consumerReport.schema_version !== REPORT_SCHEMA_VERSION ||
      consumerReport.status !== "consumer-build-pass") {
    throw new Error("a passing relocated consumer report is required before browser qualification");
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{5,127}$/.test(runId)) throw new Error("run_id is malformed");
  const aggregateStarted = now().toISOString();
  const identity = identityFromConsumer(consumerReport, env);
  const report = {
    schema_version: REPORT_SCHEMA_VERSION,
    status: "qualification-running",
    run_id: runId,
    started_at: aggregateStarted,
    completed_at: null,
    elapsed_seconds: null,
    identity,
    scenario_inventory: [...SCENARIO_INVENTORY],
    scenario_reports: {},
    results: SCENARIO_INVENTORY.map(scenario =>
      createInitialResult(scenario, runId, reportPath, evidenceDirectory)),
  };
  mkdirSync(evidenceDirectory, { recursive: true });
  atomicWriteJson(reportPath, report);
  const startedClock = monotonicNow();
  const scenarioIntervals = {};
  let failureMessage = null;

  for (let index = 0; index < SCENARIO_INVENTORY.length; index += 1) {
    const scenario = SCENARIO_INVENTORY[index];
    const result = report.results[index];
    if (signal?.aborted) {
      result.status = "cancelled";
      result.child.cancelled = true;
      result.completed_at = now().toISOString();
      failureMessage = "qualification was cancelled before the next browser scenario";
      for (const remaining of report.results.slice(index + 1)) remaining.status = "not-run";
      break;
    }

    const scenarioDirectory = path.join(evidenceDirectory, "scenarios", scenario);
    mkdirSync(scenarioDirectory, { recursive: true });
    const browserReportPath = path.join(scenarioDirectory, "browser-report.json");
    result.status = "running";
    result.started_at = now().toISOString();
    atomicWriteJson(reportPath, report);
    const spec = {
      scenario,
      runId,
      attempt: 1,
      executable: process.execPath,
      args: [cdpScriptPath ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "cdp.mjs")],
      reportPath: browserReportPath,
      stdoutPath: path.join(scenarioDirectory, "runner.stdout.log"),
      stderrPath: path.join(scenarioDirectory, "runner.stderr.log"),
      browserProcessLogPath: path.join(scenarioDirectory, "browser-process.log"),
      env: {
        ...env,
        ...(consumerReportPath ? { LIBFUTURO_CONSUMER_REPORT: consumerReportPath } : {}),
        LIBFUTURO_BROWSER_SCENARIO: scenario,
        LIBFUTURO_BROWSER_REPORT: browserReportPath,
        LIBFUTURO_BROWSER_PROCESS_LOG: path.join(scenarioDirectory, "browser-process.log"),
        LIBFUTURO_BROWSER_RUN_ID: runId,
        LIBFUTURO_BROWSER_ATTEMPT: "1",
      },
    };
    const childStarted = monotonicNow();
    let outcome;
    try {
      outcome = await spawnScenario(spec, { signal, timeoutMs });
    } catch (error) {
      outcome = {
        exitCode: null,
        signal: null,
        timedOut: false,
        cancelled: signal?.aborted === true,
        spawnError: cleanMessage(error.message),
      };
    }
    const childCompletedMonotonic = monotonicNow();
    const childCompleted = now();
    result.completed_at = childCompleted.toISOString();
    result.elapsed_seconds = Math.max(0, (childCompletedMonotonic - childStarted) / 1000);
    scenarioIntervals[scenario] = {
      start: childStarted,
      end: childCompletedMonotonic,
      unit: "milliseconds",
    };
    result.child = {
      exit_code: Number.isInteger(outcome?.exitCode) ? outcome.exitCode : null,
      signal: typeof outcome?.signal === "string" ? outcome.signal : null,
      timed_out: outcome?.timedOut === true,
      cancelled: outcome?.cancelled === true || signal?.aborted === true,
      ...(outcome?.cleanupTimedOut === true ? { cleanup_timed_out: true } : {}),
      ...(outcome?.spawnError ? { spawn_error: cleanMessage(outcome.spawnError) } : {}),
    };

    let browserReport = outcome?.browserReport;
    if (!browserReport && existsSync(browserReportPath)) {
      try { browserReport = JSON.parse(readFileSync(browserReportPath, "utf8")); }
      catch (error) { result.report_error = `browser report JSON could not be parsed: ${cleanMessage(error.message)}`; }
    }
    if (objectLike(browserReport)) {
      attachQualificationMetadata(browserReport, result, runId, childCompleted.toISOString());
      atomicWriteJson(browserReportPath, browserReport);
      report.scenario_reports[scenario] = embeddedScenarioReport(browserReport);
    }
    if (objectLike(browserReport) && result.child.exit_code === 0 && result.child.signal === null &&
        result.child.timed_out === false && result.child.cancelled === false &&
        browserReport.status === "browser-pass") {
      result.status = "pass";
    } else {
      result.status = result.child.cancelled ? "cancelled" : "failed";
      failureMessage = result.report_error ?? result.child.spawn_error ??
        (result.child.timed_out ? `${scenario} browser child timed out` :
          result.child.cancelled ? `${scenario} browser child was cancelled` :
            `${scenario} browser child did not produce a passing report and zero exit`);
      for (const remaining of report.results.slice(index + 1)) remaining.status = "not-run";
      break;
    }
    atomicWriteJson(reportPath, report);
  }

  report.completed_at = now().toISOString();
  report.elapsed_seconds = Math.max(0, (monotonicNow() - startedClock) / 1000);
  report.timings = aggregateTimingEvidence(consumerReport.timings, report.results, scenarioIntervals);
  if (failureMessage) {
    report.status = "qualification-failed";
    report.failure = { message: cleanMessage(failureMessage) };
    atomicWriteJson(reportPath, report);
    emit(report);
    return report;
  }

  const candidate = { ...report, status: "qualification-pass" };
  const validation = validateAggregate(candidate, {
    baseDirectory: path.dirname(reportPath),
    allowProvisionalTimings: true,
    requireEmbeddedScenarioReports: true,
  });
  if (!validation.valid) {
    report.status = "qualification-failed";
    report.failure = { message: "aggregate failed strict validation", validation_errors: validation.errors };
    atomicWriteJson(reportPath, report);
    emit(report);
    return report;
  }

  report.status = "qualification-finalizing";
  atomicWriteJson(reportPath, report);
  if (consumerReportPath && existsSync(consumerReportPath)) {
    const currentConsumerReport = JSON.parse(readFileSync(consumerReportPath, "utf8"));
    currentConsumerReport.browser = {
      ...(currentConsumerReport.browser ?? {}),
      status: "qualification-finalizing",
      qualification_report: relativeEvidencePath(consumerReportPath, reportPath),
      scenario_count: SCENARIO_INVENTORY.length,
      scenarios: SCENARIO_INVENTORY.map(scenario => ({ name: scenario, status: "pass" })),
      elapsed_seconds: report.elapsed_seconds,
    };
    atomicWriteJson(consumerReportPath, currentConsumerReport);
  }
  emit(report);
  return report;
}

function emitCliAggregate(report) {
  printAggregate(report);
}

async function runCli() {
  const args = process.argv.slice(2);
  if (args.length === 6 && args[0] === "--finalize-timings") {
    const reportPath = path.resolve(args[1]);
    const consumerReportPath = path.resolve(args[2]);
    try {
      const aggregate = finalizeAggregateTimings(reportPath, args[3], args[4], args[5], consumerReportPath);
      process.stdout.write(`Qualification timing finalization: PASS (${SCENARIO_INVENTORY.length} scenarios)\n`);
      printFinalAggregate(aggregate);
    } catch (error) {
      process.stderr.write(`Qualification timing finalization: FAIL (${cleanMessage(error.message)})\n`);
      process.exitCode = 1;
    }
    return;
  }
  if (args.length === 2 && args[0] === "--validate") {
    const reportPath = path.resolve(args[1]);
    let aggregate;
    try { aggregate = JSON.parse(readFileSync(reportPath, "utf8")); }
    catch (error) {
      process.stderr.write(`Qualification validation: FAIL (${cleanMessage(error.message)})\n`);
      process.exitCode = 1;
      return;
    }
    const validation = validateAggregate(aggregate, { baseDirectory: path.dirname(reportPath) });
    if (!validation.valid) {
      process.stderr.write(`Qualification validation: FAIL\n${validation.errors.map(error => `- ${error}`).join("\n")}\n`);
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`Qualification validation: PASS (${SCENARIO_INVENTORY.length} scenarios)\n`);
    return;
  }
  if (args.length !== 1 || args[0] !== "--run") {
    process.stderr.write("Usage: qualification.mjs --run | --validate REPORT | --finalize-timings REPORT CONSUMER_REPORT OUTER_START_NS OUTER_SETUP_END_NS OUTER_END_NS\n");
    process.exitCode = 2;
    return;
  }

  const reportPath = process.env.LIBFUTURO_BROWSER_QUALIFICATION_REPORT ??
    "/work/evidence/browser-qualification.json";
  const evidenceDirectory = process.env.LIBFUTURO_BROWSER_QUALIFICATION_EVIDENCE ??
    path.join(path.dirname(reportPath), "qualification");
  const consumerReportPath = process.env.LIBFUTURO_CONSUMER_REPORT;
  if (!consumerReportPath) {
    process.stderr.write("error: missing LIBFUTURO_CONSUMER_REPORT\n");
    process.exitCode = 2;
    return;
  }
  let consumerReport;
  try { consumerReport = JSON.parse(readFileSync(consumerReportPath, "utf8")); }
  catch (error) {
    process.stderr.write(`error: consumer report could not be read (${cleanMessage(error.message)})\n`);
    process.exitCode = 2;
    return;
  }

  const controller = new AbortController();
  let receivedSignal = null;
  const onInterrupt = () => {
    receivedSignal = "SIGINT";
    controller.abort(receivedSignal);
  };
  const onTerminate = () => {
    receivedSignal = "SIGTERM";
    controller.abort(receivedSignal);
  };
  process.once("SIGINT", onInterrupt);
  process.once("SIGTERM", onTerminate);
  try {
    const aggregate = await runQualification({
      reportPath,
      evidenceDirectory,
      consumerReport,
      consumerReportPath,
      cdpScriptPath: fileURLToPath(new URL("./cdp.mjs", import.meta.url)),
      env: process.env,
      signal: controller.signal,
      emit: emitCliAggregate,
    });
    if (aggregate.status !== "qualification-finalizing") process.exitCode = receivedSignal === "SIGINT" ? 130 : receivedSignal === "SIGTERM" ? 143 : 1;
  } catch (error) {
    process.stderr.write(`error: browser qualification could not complete (${cleanMessage(error.message)})\n`);
    process.exitCode = 1;
  } finally {
    process.removeListener("SIGINT", onInterrupt);
    process.removeListener("SIGTERM", onTerminate);
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await runCli();
}
