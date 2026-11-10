import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseGeneratedLinkCommand, runQualification } from "./qualification.mjs";

function consumerTimings() {
  const ns = seconds => seconds * 1e9;
  const interval = (start, end) => ({ start: ns(start), end: ns(end), unit: "nanoseconds" });
  return {
    schema_version: 1,
    finalized: false,
    clock_domains: {
      outer: "host CLOCK_MONOTONIC via Perl Time::HiRes",
      container: "SDK container CLOCK_MONOTONIC via Perl Time::HiRes",
      scenarios: "Node qualification-process performance.now()",
    },
    stage_clock_domains: {
      outer_setup_image_acquisition: "outer", docker_run: "outer",
      package_configure: "container", package_build: "container",
      package_install_relocation: "container", consumer_configure: "container",
      consumer_build: "container", browser_setup: "container",
      scenario_execution: "scenarios", scenarios: "scenarios", total: "outer",
    },
    durations_seconds: {
      outer_setup_image_acquisition: 2, package_configure: 1, package_build: 2,
      package_install_relocation: 3, consumer_configure: 1, consumer_build: 2,
      browser_setup: 1, scenario_execution: null, scenarios: {}, docker_run: null, total: null,
    },
    intervals: {
      outer_setup_image_acquisition: interval(0, 2), docker_run: null, total: null,
      package_configure: interval(3, 4), package_build: interval(4, 6),
      package_install_relocation: interval(6, 9), consumer_configure: interval(9, 10),
      consumer_build: interval(10, 12), browser_setup: interval(12, 13), scenarios: {},
    },
    cache_observations: {
      sdk_image: "verified-hit", browser_archive: "verified-hit", apt_packages: "not-claimed-unverified",
    },
    queue: {
      status: "not-available-locally", seconds: null,
      source: "hosted GitHub Actions run/job records only (Plan 03-05)",
    },
    nesting: {
      total_includes: ["outer_setup_image_acquisition", "docker_run"],
      docker_run_contains: ["package_configure", "package_build", "package_install_relocation",
        "consumer_configure", "consumer_build", "browser_setup", "scenario_execution"],
      scenario_execution: "sum-of-serial-scenario-intervals",
      warning: "container and scenario stage durations are nested inside docker_run; do not add them to total",
    },
  };
}

export const browserEnv = Object.freeze({
  LIBFUTURO_SOURCE_SNAPSHOT: "worktree-snapshot",
  LIBFUTURO_BROWSER_VERSION: "157.0.8103.50",
  LIBFUTURO_BROWSER_ARCHIVE_SHA256: "2".repeat(64),
  LIBFUTURO_CFT_REVISION: "1717349",
  LIBFUTURO_SDK_PLATFORM: "linux/amd64",
});

export function consumerReport({
  sourceCommit = "a".repeat(40),
  sourceTree = "9".repeat(40),
  sourceSnapshotKind = "worktree-snapshot",
  outerRunner = null,
} = {}) {
  const linkCommand = parseGeneratedLinkCommand(
    "emcc -O3 -sENVIRONMENT=web -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16 -sEXIT_RUNTIME=0 CMakeFiles/libfuturo_web_consumer.dir/consumer.c.o -o artifacts/consumer.js /work/relocated/lib/libfuturo-web.a /work/relocated/lib/libmuhtari.a\n",
    { buildDirectory: "/work/consumer-build", relocatedPrefix: "/work/relocated" },
  );
  return {
    schema_version: 2,
    status: "consumer-build-pass",
    source_commit: sourceCommit,
    source_tree: sourceTree,
    source_snapshot_kind: sourceSnapshotKind,
    outer_runner: outerRunner ?? {
      kind: "local", os: "darwin", architecture: "arm64",
      runner_name: { applicability: "not-applicable", value: null },
      image_version: { applicability: "not-applicable", value: null },
      github_actions: {
        applicability: "not-applicable", sha: null, run_id: null, run_attempt: null,
        workflow: null, job: null, event_name: null,
      },
    },
    docker_daemon: { platform: "linux/aarch64" },
    container: {
      os_name: "Ubuntu 24.04.3 LTS", architecture: "x86_64",
      node_version: "v22.15.0", node_platform: "linux", node_architecture: "x64",
      node_versions: { modules: "127", v8: "12.4.254.21-node.22", uv: "1.50.0" },
    },
    package: {
      target: "libfuturo::web",
      core: "muhtari",
      core_version: "0.11.1",
      core_source_revision: "d58f125297c4d63a7a8108112a5eafff6f53a76a",
      api_revision: 8,
      abi_revision: 1,
      behavior_revision: 6,
      profile: "muhtari-ntsc-v2",
      configuration: "muhtari-ntsc-battery-diagnostic",
      libfuturo_build_id: "web-build-test",
      archive_sha256: "b".repeat(64),
      core_archive_sha256: "c".repeat(64),
    },
    fixture_metadata: {
      id: "generated-muhtari-a78-api8-v1",
      bytes: 16512,
      sha256: "d".repeat(64),
      loaded_or_read: false,
    },
    sdk: {
      image: "emscripten/emsdk:7.0.0@sha256:" + "e".repeat(64),
      requested_platform: "linux/amd64",
      resolved_platform: "linux/amd64",
      container_architecture: "x86_64",
      compiler: "emcc (Emscripten gcc/clang-like replacement) 4.0.0",
    },
    consumer: {
      javascript_sha256: "f".repeat(64),
      host_controller_sha256: "8".repeat(64),
      wasm_sha256: "1".repeat(64),
      link_command: linkCommand,
    },
    browser: {
      runtime_packages_classification: "installed-unpinned",
      runtime_packages: ["libc6=2.39-0ubuntu8", "libglib2.0-0t64=2.80.0-6ubuntu3.1"],
    },
    timings: consumerTimings(),
  };
}

function scenarioEvidence(scenario) {
  if (scenario === "identity") {
    return {
      positive: { result: "pass", instance_created: true, instance_destroyed: true, load_called: false },
      mismatch: { result: "pass", status: 1, load_called: false, content_accessed: false },
    };
  }
  if (scenario === "host-tracer") {
    return { tracer: { result: "pass", raw_index_oracle: "pass", canvas_oracle: "pass",
      changed_pixel_control: "rejected", start_trusted: true, user_activation: true,
      audio_graph_rms: 0.25, progress: 2, frame_progress: 2, input_buttons: 0 } };
  }
  if (scenario === "host-content") {
    return { content: { result: "pass", valid_retry: true, valid_retry_frame_oracle: true,
      valid_retry_frame_progress: 2, valid_retry_input_buttons: 0,
      privacy_clean: true, start_trusted: true, user_activation: true } };
  }
  if (scenario === "host-input") {
    return { input: { result: "pass", all_five_bits: true, combined_input: true,
      repeat_ignored: true, keyup_release: true, focus_loss_clear: true, hidden_clear: true } };
  }
  if (scenario === "host-input-audio") {
    return { audio: { result: "pass", trusted_start: true, user_activation: true,
      oracle_pcm_validation: true, changed_sample_control_rejected: true, queue_bounded: true,
      suspension_paused: true, no_auto_resume: true } };
  }
  if (scenario === "host-lifecycle") {
    return { lifecycle: { result: "pass", stop_destroys_once: true, stale_callback_no_calls: true,
      pagehide_paused: true, pagehide_input_cleared: true, pagehide_audio_discarded: true,
      audio_retirement: { queued_before_hide: true, queue_frames_before_hide: 1,
        queue_samples_before_hide: 800, sources_stopped_before_hide: 4,
        sources_stopped_after_hide: 5, source_retired_on_hide: true } } };
  }
  return { ui: { result: "pass", runtime_error_state: true, stopped_state: true,
    keyboard_focus: true, semantic_contract: true } };
}

export function browserReportFor(scenario, consumer, env = browserEnv) {
  return {
    schema_version: 2,
    status: "browser-pass",
    sdk: {
      image: consumer.sdk.image,
      requested_platform: consumer.sdk.requested_platform,
      resolved_platform: consumer.sdk.resolved_platform,
      container_architecture: consumer.sdk.container_architecture,
      compiler: consumer.sdk.compiler,
    },
    source_tree: consumer.source_tree,
    outer_runner: consumer.outer_runner,
    docker_daemon: consumer.docker_daemon,
    container: consumer.container,
    identity_assurance: "lineage-and-mismatch-detection; not authentication or attestation",
    browser: {
      version_expected: env.LIBFUTURO_BROWSER_VERSION,
      binary_version: `Chrome for Testing Headless Shell ${env.LIBFUTURO_BROWSER_VERSION}`,
      archive_sha256: env.LIBFUTURO_BROWSER_ARCHIVE_SHA256,
      archive_sha256_expected: env.LIBFUTURO_BROWSER_ARCHIVE_SHA256,
      release_revision: env.LIBFUTURO_CFT_REVISION,
      requested_platform: env.LIBFUTURO_SDK_PLATFORM,
      container_architecture: consumer.sdk.container_architecture,
      runtime_packages_classification: consumer.browser.runtime_packages_classification,
      runtime_packages: consumer.browser.runtime_packages,
    },
    input: {
      source_snapshot_kind: env.LIBFUTURO_SOURCE_SNAPSHOT,
      source_commit: consumer.source_commit,
      source_tree: consumer.source_tree,
      target: consumer.package.target,
      core: consumer.package.core,
      core_version: consumer.package.core_version,
      core_source_revision: consumer.package.core_source_revision,
      package_build_id: consumer.package.libfuturo_build_id,
      package_archive_sha256: consumer.package.archive_sha256,
      core_archive_sha256: consumer.package.core_archive_sha256,
      profile: consumer.package.profile,
      configuration: consumer.package.configuration,
      api_revision: consumer.package.api_revision,
      abi_revision: consumer.package.abi_revision,
      behavior_revision: consumer.package.behavior_revision,
      fixture_metadata: consumer.fixture_metadata,
      javascript_sha256: consumer.consumer.javascript_sha256,
      host_controller_sha256: consumer.consumer.host_controller_sha256,
      wasm_sha256: consumer.consumer.wasm_sha256,
      link_command: consumer.consumer.link_command,
    },
    scenarios: scenarioEvidence(scenario),
  };
}

export function makeLogFiles(spec) {
  writeFileSync(spec.stdoutPath, "", { mode: 0o600 });
  writeFileSync(spec.stderrPath, "", { mode: 0o600 });
  writeFileSync(spec.browserProcessLogPath, "", { mode: 0o600 });
}

export async function createPassingRun({
  sourceCommit = "a".repeat(40),
  sourceTree = "9".repeat(40),
  sourceSnapshotKind = "worktree-snapshot",
  outerRunner = null,
  runId = "run-valid-control-01",
} = {}) {
  const root = mkdtempSync(path.join(os.tmpdir(), "browser-qualification-valid-"));
  try {
    const env = { ...browserEnv, LIBFUTURO_SOURCE_SNAPSHOT: sourceSnapshotKind };
    const consumer = consumerReport({ sourceCommit, sourceTree, sourceSnapshotKind, outerRunner });
    const consumerReportPath = path.join(root, "consumer-report.json");
    writeFileSync(consumerReportPath, JSON.stringify(consumer));
    const reportPath = path.join(root, "browser-qualification.json");
    const evidenceDirectory = path.join(root, "qualification");
    const provisional = await runQualification({
      reportPath,
      evidenceDirectory,
      consumerReport: consumer,
      consumerReportPath,
      runId,
      env,
      spawnScenario: async spec => {
        makeLogFiles(spec);
        return {
          exitCode: 0,
          signal: null,
          timedOut: false,
          cancelled: false,
          browserReport: browserReportFor(spec.scenario, consumer, env),
        };
      },
    });
    if (provisional.status !== "qualification-finalizing") {
      throw new Error(`synthetic qualification failed: ${provisional.failure?.message ?? provisional.status}`);
    }
    const cli = fileURLToPath(new URL("./qualification.mjs", import.meta.url));
    const finalized = spawnSync(process.execPath,
      [cli, "--finalize-timings", reportPath, consumerReportPath, "0", String(2e9), String(20e9)],
      { encoding: "utf8" });
    if (finalized.status !== 0) throw new Error(finalized.stderr || "synthetic qualification finalization failed");
    const report = JSON.parse(readFileSync(reportPath, "utf8"));
    if (report.status !== "qualification-pass") throw new Error("synthetic qualification did not pass");
    return {
      root,
      reportPath,
      evidenceDirectory,
      report,
      finalizeOutput: finalized.stdout,
      cleanup: () => rmSync(root, { recursive: true, force: true }),
    };
  } catch (error) {
    rmSync(root, { recursive: true, force: true });
    throw error;
  }
}
