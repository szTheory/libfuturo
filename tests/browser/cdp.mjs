import { createHash, randomBytes } from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { createServer } from "node:http";
import { createReadStream, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, createWriteStream } from "node:fs";
import { once } from "node:events";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const requiredEnv = [
  "LIBFUTURO_BROWSER_BINARY",
  "LIBFUTURO_BROWSER_VERSION",
  "LIBFUTURO_BROWSER_ARCHIVE",
  "LIBFUTURO_BROWSER_ARCHIVE_SHA256",
  "LIBFUTURO_CFT_REVISION",
  "LIBFUTURO_CFT_URL",
  "LIBFUTURO_CONSUMER_DIR",
  "LIBFUTURO_CONSUMER_REPORT",
  "LIBFUTURO_BROWSER_REPORT",
  "LIBFUTURO_BROWSER_RUNTIME_PACKAGES",
  "LIBFUTURO_SDK_IMAGE",
  "LIBFUTURO_SDK_PLATFORM",
  "LIBFUTURO_SOURCE_REVISION",
];

function requireEnvironment() {
  for (const name of requiredEnv) {
    if (!process.env[name]) throw new Error(`missing environment setting: ${name}`);
  }
  if (typeof WebSocket !== "function") {
    throw new Error("this pinned Node runtime does not provide its built-in WebSocket");
  }
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function hashFile(filePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  return hash.digest("hex");
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function cleanMessage(value) {
  return String(value ?? "").replace(/(?:https?|file):\/\/[^\s)]+/g, "[url]").slice(0, 320);
}

class CdpConnection {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 0;
    this.pending = new Map();
    this.listeners = new Set();
    socket.addEventListener("message", event => {
      let message;
      try {
        message = JSON.parse(typeof event.data === "string" ? event.data : String(event.data));
      } catch {
        this.listeners.forEach(listener => listener({ method: "Harness.protocolError" }));
        return;
      }
      if (Number.isInteger(message.id)) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        clearTimeout(pending.timer);
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(`CDP ${pending.method} failed: ${message.error.message}`));
        else pending.resolve(message.result ?? {});
      } else if (message.method) {
        this.listeners.forEach(listener => listener(message));
      }
    });
    socket.addEventListener("close", () => {
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error("CDP connection closed before a command completed"));
      }
      this.pending.clear();
    });
  }

  static async connect(url) {
    const socket = new WebSocket(url);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timed out connecting to the local CDP endpoint")), 10_000);
      socket.addEventListener("open", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      socket.addEventListener("error", () => {
        clearTimeout(timer);
        reject(new Error("could not connect to the local CDP endpoint"));
      }, { once: true });
    });
    return new CdpConnection(socket);
  }

  onEvent(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  send(method, params = {}) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`timed out waiting for CDP ${method}`));
      }, 10_000);
      this.pending.set(id, { method, resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    if (this.socket.readyState === WebSocket.OPEN) this.socket.close();
  }
}

function expectedScenarioResults(packageInfo, browserPayload, scenario) {
  if (!browserPayload || !browserPayload.results || !browserPayload.failures) {
    throw new Error("browser page did not return the expected result envelope");
  }
  if (browserPayload.failures.length !== 0) {
    throw new Error("browser page reported a runtime failure");
  }

  if (scenario === "identity") {
    const positive = browserPayload.results.positive;
    const mismatch = browserPayload.results.mismatch;
    const expectedCoreBuild = `muhtari-${packageInfo.core_source_revision}`;
    if (!positive || positive.result !== "pass" ||
        positive.profile !== packageInfo.profile || positive.core !== packageInfo.core ||
        positive.core_build !== expectedCoreBuild || positive.api !== packageInfo.api_revision ||
        positive.abi !== packageInfo.abi_revision ||
        positive.behavior !== packageInfo.behavior_revision ||
        positive.configuration !== packageInfo.configuration ||
        positive.libfuturo_build !== packageInfo.libfuturo_build_id ||
        positive.instance_created !== true || positive.instance_destroyed !== true ||
        positive.load_called !== false) {
      throw new Error("positive browser identity result did not match the installed package report");
    }
    if (!mismatch || mismatch.result !== "pass" || !Number.isInteger(mismatch.status) ||
        mismatch.status === 0 || mismatch.load_called !== false ||
        mismatch.content_accessed !== false) {
      throw new Error("mismatched identity was not refused before content access");
    }
    return { positive, mismatch };
  }
  if (scenario === "host-tracer") {
    const tracer = browserPayload.results.tracer;
    if (!tracer || tracer.result !== "pass" || tracer.profile !== packageInfo.profile ||
        tracer.configuration !== packageInfo.configuration || tracer.api !== packageInfo.api_revision ||
        tracer.raw_index_oracle !== "pass" || tracer.canvas_oracle !== "pass" ||
        tracer.changed_pixel_control !== "rejected" || tracer.start_trusted !== true ||
        tracer.user_activation !== true || tracer.audio_rate !== 48000 ||
        !Number.isFinite(tracer.audio_graph_rms) || tracer.audio_graph_rms <= 0 ||
        tracer.instance_created !== true ||
        tracer.load_called !== 1 || tracer.progress !== 2 ||
        tracer.frame_progress !== 2 || tracer.input_buttons !== 0) {
      throw new Error("installed browser host tracer failed its public-core boundary checks");
    }
    return { tracer };
  }
  if (scenario === "host-content") {
    const content = browserPayload.results.content;
    const runtimeSnapshots = new Map((content?.module_runtime_snapshots ?? [])
      .filter(snapshot => typeof snapshot?.label === "string")
      .map(snapshot => [snapshot.label, snapshot]));
    const apiReadyAt = label => {
      const snapshot = runtimeSnapshots.get(label);
      const types = snapshot?.public_api_types;
      return types && Object.values(types).length === 6 &&
        Object.values(types).every(type => type === "function") &&
        snapshot.same_initial_module === true && snapshot.same_initial_host === true;
    };
    if (!content || content.result !== "pass" || content.profile_first !== true ||
        content.initialize_profile_queries !== 1 ||
        !(content.first_read_profile_queries_before > content.initialize_profile_queries) ||
        content.first_read_count_before !== 0 || content.first_read_profile_gate_before !== true ||
        !Array.isArray(content.profile_gate_before_reads) ||
        content.profile_gate_before_reads.length !== 3 ||
        content.profile_gate_before_reads.some(value => value !== true) ||
        content.empty_read_delta !== 0 || content.empty_wasm_copy_delta !== 0 ||
        content.empty_copy_delta !== 0 || content.empty_load_delta !== 0 ||
        content.empty_progress_delta !== 0 || content.empty_advance_delta !== 0 ||
        content.oversized_read_delta !== 0 ||
        content.oversized_wasm_copy_delta !== 0 || content.oversized_copy_delta !== 0 ||
        content.oversized_load_delta !== 0 || content.oversized_progress_delta !== 0 ||
        content.oversized_advance_delta !== 0 ||
        content.malformed_read_delta !== 1 || content.malformed_wasm_copy_delta !== 1 ||
        content.malformed_copy_delta !== 1 || content.malformed_load_delta !== 1 ||
        content.malformed_progress_delta !== 0 || content.malformed_advance_delta !== 0 ||
        content.malformed_canvas_blank !== true ||
        content.malformed_generic_status !== true ||
        content.truncated_read_delta !== 1 || content.truncated_wasm_copy_delta !== 1 ||
        content.truncated_copy_delta !== 1 || content.truncated_load_delta !== 1 ||
        content.truncated_progress_delta !== 0 || content.truncated_advance_delta !== 0 ||
        content.truncated_canvas_blank !== true ||
        content.truncated_generic_status !== true || content.valid_retry !== true ||
        content.valid_retry_load_delta !== 1 || content.valid_retry_frame_oracle !== true ||
        content.valid_retry_frame_progress !== 2 || content.valid_retry_input_buttons !== 0 ||
        content.start_trusted !== true || content.user_activation !== true ||
        content.privacy_clean !== true || content.request_scan_complete !== true ||
        content.request_methods_get_only !== true || content.request_urls_clean !== true ||
        content.storage_clean !== true || content.minimized_hidden !== true ||
        content.restored_visible !== true || content.same_origin_bfcache !== true ||
        content.bfcache_qualification !== "not-qualified" ||
        !apiReadyAt("content-start") || !apiReadyAt("after-empty-refusal") ||
        !apiReadyAt("after-oversized-refusal") || !apiReadyAt("after-malformed-refusal") ||
        !apiReadyAt("after-truncated-refusal") || !apiReadyAt("after-valid-retry") ||
        !runtimeSnapshots.has("next-document-loaded") || !apiReadyAt("next-runtime-ready") ||
        !runtimeSnapshots.has("history-return-document-loaded") ||
        !apiReadyAt("history-return-runtime-ready") ||
        typeof content.bfcache_persisted !== "boolean" ||
        !Number.isFinite(content.audio_graph_rms) || content.audio_graph_rms <= 0) {
      throw new Error("installed browser content scenario failed refusal, retry, privacy, or lifecycle checks");
    }
    return { content };
  }
  if (scenario === "host-input") {
    const input = browserPayload.results.input;
    if (!input || input.result !== "pass" || input.profile_cadence !== true ||
        input.scheduler_probe !== true || input.scheduler_60hz_exact !== true ||
        input.scheduler_no_catch_up !== true ||
        input.scheduler_reentrant_rejected !== true || input.focused_canvas !== true ||
        input.all_five_bits !== true || input.combined_input !== true ||
        input.repeat_ignored !== true || input.repeat_default_prevented !== true ||
        input.keyup_release !== true ||
        input.focus_loss_clear !== true || input.hidden_clear !== true ||
        input.minimized_hidden !== true || input.restored_visible !== true ||
        input.no_hidden_catch_up !== true) {
      throw new Error("installed browser input scenario failed cadence, mapping, release, or hidden-state checks");
    }
    return { input };
  }
  if (scenario === "host-input-audio") {
    const audio = browserPayload.results.audio;
    if (!audio || audio.result !== "pass" || audio.trusted_start !== true ||
        audio.user_activation !== true || audio.audio_rate_48khz !== true ||
        audio.no_context_before_start !== true || audio.single_context_on_resume !== true ||
        audio.failed_start_cleanup !== true || audio.failed_start_error !== true ||
        audio.failed_start_retry !== true ||
        audio.resume_failure_preserved !== true || audio.resume_failure_error !== true ||
        audio.resume_failure_retry !== true ||
        audio.mono_buffers !== true || audio.oracle_counts !== true ||
        audio.oracle_pcm_validation !== true || audio.changed_sample_control_rejected !== true ||
        audio.queue_bounded !== true ||
        audio.graph_active !== true || audio.suspension_paused !== true ||
        audio.suspension_cleared_input !== true || audio.suspension_retired_sources !== true ||
        audio.no_auto_resume !== true || audio.explicit_resume_advanced !== true) {
      throw new Error("installed browser audio scenario failed activation, PCM, queue, or interruption checks");
    }
    return { audio };
  }
  if (scenario === "host-lifecycle") {
    const lifecycle = browserPayload.results.lifecycle;
    if (!lifecycle || lifecycle.result !== "pass" ||
        lifecycle.minimized_hidden !== true || lifecycle.hidden_input_cleared !== true ||
        lifecycle.hidden_audio_discarded !== true || lifecycle.hidden_status_correct !== true ||
        lifecycle.restored_visible_paused !== true || lifecycle.no_hidden_catch_up !== true ||
        lifecycle.restored_status_correct !== true ||
        lifecycle.explicit_resume_advanced !== true || lifecycle.pagehide_observed !== true ||
        lifecycle.pagehide_paused !== true || lifecycle.pagehide_input_cleared !== true ||
        lifecycle.pagehide_audio_discarded !== true || lifecycle.stop_api_available !== true ||
        lifecycle.stop_destroys_once !== true || lifecycle.stale_callback_no_calls !== true ||
        lifecycle.same_origin_bfcache !== true || lifecycle.bfcache_persisted !== false ||
        !Array.isArray(lifecycle.bfcache_not_restored_reasons) ||
        !lifecycle.bfcache_not_restored_reasons.includes("BrowsingInstanceNotSwapped") ||
        !lifecycle.bfcache_not_restored_reasons.includes("BackForwardCacheDisabledForDelegate")) {
      throw new Error("installed browser lifecycle scenario failed hidden, pagehide, or teardown assertions");
    }
    return { lifecycle };
  }
  if (scenario === "host-ui") {
    const ui = browserPayload.results.ui;
    const required = [
      "initial_empty", "initial_controls", "semantic_contract", "layout_contract",
      "narrow_warning_no_overflow", "stop_warning_beside_stop", "spacing_contract",
      "keyboard_focus", "light_warning", "dark_warning", "forced_color_warning",
      "checking_state", "accepted_state", "empty_rejected", "oversize_rejected",
      "malformed_rejected", "privacy_clean", "running_state", "minimized_hidden",
      "hidden_status", "restored_paused", "restored_status", "no_auto_resume",
      "explicit_resume", "paused_state", "audio_interrupted", "audio_no_auto_resume",
      "audio_explicit_resume", "runtime_error_state", "stopped_state",
    ];
    const failed = required.filter(key => ui?.[key] !== true);
    if (!ui || ui.result !== "pass" || failed.length > 0) {
      throw new Error("installed browser UI scenario failed checks: " + failed.join(", "));
    }
    return { ui };
  }
  throw new Error(`unsupported pinned browser scenario: ${scenario}`);
}

async function evaluate(cdp, expression) {
  const response = await cdp.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (response.exceptionDetails) {
    const description = response.exceptionDetails.exception?.description ??
      response.exceptionDetails.text ?? "JavaScript exception";
    const message = String(description).split("\n", 1)[0];
    let runtimeDiagnostics = null;
    try {
      const diagnostics = await cdp.send("Runtime.evaluate", {
        expression: `(() => {
          const moduleObject = window.Module;
          const names = ["_lfweb_profile_query_count", "_lfweb_content_copy_count",
            "_lfweb_load_call_count", "_lfweb_advance_call_count", "_lfweb_profile_matches",
            "_lfweb_load_buffer"];
          const identityMap = window.__libfuturoModuleIdentityMap;
          const moduleId = identityMap && moduleObject &&
            (typeof moduleObject === "object" || typeof moduleObject === "function")
            ? identityMap.get(moduleObject) ?? null
            : null;
          const initialModule = window.__libfuturoInitialModule;
          const hostObject = window.LibFuturoHost;
          const hostId = identityMap && hostObject && typeof hostObject === "object"
            ? identityMap.get(hostObject) ?? null
            : null;
          const asm = moduleObject?.asm ?? moduleObject?.wasmExports;
          return {
            label: "evaluation-exception",
            href: location.href,
            documentComplete: document.readyState,
            pageComplete: document.body?.dataset.complete ?? null,
            pageResult: document.body?.dataset.result ?? null,
            typeofModule: typeof Module,
            windowModuleType: typeof window.Module,
            globalBindingSameAsWindow: typeof Module === "undefined"
              ? false
              : Module === window.Module,
            module_available: Boolean(moduleObject && typeof moduleObject === "object"),
            module_id: moduleId,
            initial_module_id: initialModule && identityMap
              ? identityMap.get(initialModule) ?? null
              : null,
            same_initial_module: Boolean(initialModule && moduleObject === initialModule),
            module_own_keys: moduleObject && (typeof moduleObject === "object" ||
              typeof moduleObject === "function")
              ? Object.getOwnPropertyNames(moduleObject).sort().slice(0, 160)
              : [],
            public_api_types: Object.fromEntries(names.map(name => [name, typeof moduleObject?.[name]])),
            runtime_export_names: asm && typeof asm === "object"
              ? Object.keys(asm).sort()
              : null,
            host_object_available: Boolean(hostObject && typeof hostObject === "object"),
            host_object_id: hostId,
            same_initial_host: Boolean(window.__libfuturoInitialHost &&
              hostObject === window.__libfuturoInitialHost),
            runtime_flags: moduleObject && typeof moduleObject === "object"
              ? {
                  calledRun: moduleObject.calledRun ?? null,
                  runtimeInitialized: moduleObject.runtimeInitialized ?? null,
                  noExitRuntime: moduleObject.noExitRuntime ?? null,
                  heapU8Type: typeof moduleObject.HEAPU8,
                }
              : null,
            runtimeHistory: Array.isArray(window.__libfuturoModuleHistory)
              ? window.__libfuturoModuleHistory.slice(-40)
              : [],
          };
        })()`,
        returnByValue: true,
        awaitPromise: true,
      });
      runtimeDiagnostics = diagnostics.result?.value ?? null;
    } catch {
      // Preserve the original browser exception if runtime inspection is unavailable.
    }
    const error = new Error("browser host evaluation failed: " + cleanMessage(message));
    error.runtimeDiagnostics = runtimeDiagnostics;
    throw error;
  }
  return response.result?.value;
}

async function waitForValue(cdp, expression, predicate, label, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await evaluate(cdp, expression);
    if (predicate(value)) return value;
    await delay(50);
  }
  throw new Error("timed out waiting for " + label);
}

async function suspendAudioWithQueuedSource(cdp, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const before = await evaluate(cdp, `(() => {
      const report = window.LibFuturoHost.report();
      if (report.paused || report.audio_context_state !== "running" ||
          report.audio_queue_frames === 0 || report.audio_queue_samples === 0 ||
          !report.audio_active) return null;
      return window.LibFuturoHost.audioContext().suspend().then(() => report);
    })()`);
    if (before !== null) return before;
    await delay(50);
  }
  throw new Error("timed out waiting to suspend audio with a queued source");
}

async function captureModuleRuntime(cdp, label, establishInitial = false) {
  return evaluate(cdp, `(() => {
    const page = window;
    const moduleObject = page.Module;
    const identityMap = page.__libfuturoModuleIdentityMap ??= new WeakMap();
    const identityCounter = page.__libfuturoModuleIdentityCounter ??= { next: 1 };
    const identity = value => {
      if (!value || (typeof value !== "object" && typeof value !== "function")) return null;
      let id = identityMap.get(value);
      if (!id) {
        id = identityCounter.next++;
        identityMap.set(value, id);
      }
      return id;
    };
    if (${establishInitial ? "true" : "false"}) {
      page.__libfuturoInitialModule = moduleObject;
      page.__libfuturoInitialHost = page.LibFuturoHost;
    }
    const initialModule = page.__libfuturoInitialModule;
    const initialHost = page.__libfuturoInitialHost;
    const hostObject = page.LibFuturoHost;
    const names = ["_lfweb_profile_query_count", "_lfweb_content_copy_count",
      "_lfweb_load_call_count", "_lfweb_advance_call_count", "_lfweb_profile_matches",
      "_lfweb_load_buffer"];
    const asm = moduleObject?.asm ?? moduleObject?.wasmExports;
    const snapshot = {
      label: ${JSON.stringify(label)},
      href: location.href,
      document_complete: document.readyState,
      page_complete: document.body?.dataset.complete ?? null,
      page_result: document.body?.dataset.result ?? null,
      typeof_module: typeof Module,
      window_module_type: typeof page.Module,
      global_binding_same_as_window: typeof Module === "undefined" ? false : Module === page.Module,
      module_available: Boolean(moduleObject && typeof moduleObject === "object"),
      module_id: identity(moduleObject),
      initial_module_id: identity(initialModule),
      same_initial_module: Boolean(initialModule && moduleObject === initialModule),
      module_own_keys: moduleObject && (typeof moduleObject === "object" ||
        typeof moduleObject === "function")
        ? Object.getOwnPropertyNames(moduleObject).sort().slice(0, 160)
        : [],
      public_api_types: Object.fromEntries(names.map(name => [name, typeof moduleObject?.[name]])),
      runtime_export_names: asm && typeof asm === "object" ? Object.keys(asm).sort() : null,
      host_object_id: identity(hostObject),
      initial_host_id: identity(initialHost),
      same_initial_host: Boolean(initialHost && hostObject === initialHost),
      runtime_flags: moduleObject && typeof moduleObject === "object"
        ? {
            calledRun: moduleObject.calledRun ?? null,
            runtimeInitialized: moduleObject.runtimeInitialized ?? null,
            noExitRuntime: moduleObject.noExitRuntime ?? null,
            heapU8Type: typeof moduleObject.HEAPU8,
          }
        : null,
    };
    const history = page.__libfuturoModuleHistory ??= [];
    history.push(snapshot);
    return snapshot;
  })()`);
}

async function installFrameCaptureAtProgress(cdp, name, progress) {
  const globalName = JSON.stringify(name);
  const targetProgress = JSON.stringify(progress);
  await evaluate(cdp, `(() => {
    window[${globalName}] = null;
    const context = document.querySelector("#playfield").getContext("2d");
    const nativePutImageData = context.putImageData;
    Object.defineProperty(context, "putImageData", {
      configurable: true,
      value: function(...args) {
        const result = Reflect.apply(nativePutImageData, this, args);
        const state = window.LibFuturoHost.report();
        if (!window[${globalName}] && state.started &&
            state.progress === ${targetProgress}) {
          window[${globalName}] = {
            progress: state.progress,
            frame_progress: state.progress,
            input_buttons: state.input_buttons,
            raw: window.LibFuturoHost.rawFrame(),
            canvas: window.LibFuturoHost.canvasPixels(),
          };
          delete context.putImageData;
        }
        return result;
      },
    });
    return true;
  })()`);
}

async function waitForObservation(read, predicate, label, timeout = 5_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = read();
    if (predicate(value)) return value;
    await delay(25);
  }
  throw new Error("timed out waiting for " + label);
}

async function setInputFile(cdp, filePath) {
  await cdp.send("DOM.enable");
  const document = await cdp.send("DOM.getDocument", { depth: -1 });
  const input = await cdp.send("DOM.querySelector", {
    nodeId: document.root.nodeId,
    selector: "#content-file",
  });
  if (!input.nodeId) throw new Error("browser file input is unavailable");
  await cdp.send("DOM.setFileInputFiles", { files: [filePath], nodeId: input.nodeId });
}

async function clickTrusted(cdp, selector) {
  const document = await cdp.send("DOM.getDocument", { depth: -1 });
  const button = await cdp.send("DOM.querySelector", {
    nodeId: document.root.nodeId,
    selector,
  });
  if (!button.nodeId) throw new Error("browser action control is unavailable");
  const box = await cdp.send("DOM.getBoxModel", { nodeId: button.nodeId });
  const points = box.model && box.model.content;
  if (!points || points.length !== 8) throw new Error("browser action control has no visible box");
  const x = (points[0] + points[2] + points[4] + points[6]) / 4;
  const y = (points[1] + points[3] + points[5] + points[7]) / 4;
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y, buttons: 0 });
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed", x, y, button: "left", buttons: 1, clickCount: 1,
  });
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased", x, y, button: "left", buttons: 0, clickCount: 1,
  });
}

async function tapTrusted(cdp, selector) {
  const document = await cdp.send("DOM.getDocument", { depth: -1 });
  const button = await cdp.send("DOM.querySelector", {
    nodeId: document.root.nodeId,
    selector,
  });
  if (!button.nodeId) throw new Error("browser action control is unavailable");
  const box = await cdp.send("DOM.getBoxModel", { nodeId: button.nodeId });
  const points = box.model && box.model.content;
  if (!points || points.length !== 8) throw new Error("browser action control has no visible box");
  const x = (points[0] + points[2] + points[4] + points[6]) / 4;
  const y = (points[1] + points[3] + points[5] + points[7]) / 4;
  await cdp.send("Input.synthesizeTapGesture", {
    x,
    y,
    duration: 50,
    gestureSourceType: "mouse",
  });
}

function sameArray(actual, expected) {
  return Array.isArray(actual) && Array.isArray(expected) &&
    actual.length === expected.length &&
    actual.every((value, index) => value === expected[index]);
}

function expectedSteadyRawFrame(color) {
  return new Array(320 * 242).fill(color);
}

function expectedCanvasFrame(raw) {
  const expected = new Array(raw.length * 4);
  for (let index = 0; index < raw.length; index += 1) {
    const color = raw[index] === 0 ? [0, 0, 0] :
      raw[index] === 0x11 ? [0x3a, 0x2b, 0] :
      raw[index] === 0x33 ? [0x84, 0x27, 0] : null;
    if (!color) return null;
    const at = index * 4;
    expected[at] = color[0];
    expected[at + 1] = color[1];
    expected[at + 2] = color[2];
    expected[at + 3] = 0xff;
  }
  return expected;
}

async function runHostTracer(cdp, packageInfo, pagePayload, evidenceDir) {
  const inputDir = mkdtempSync(path.join(evidenceDir, "tracer-input-"));
  try {
    const bridgeTypes = await evaluate(cdp,
      "({fixture_size:typeof Module._lfweb_fixture_size,fixture_buffer:typeof Module._lfweb_fixture_buffer,profile:typeof Module._lfweb_profile_matches,heap:typeof Module.HEAPU8,subarray:typeof Module.HEAPU8?.subarray})");
    if (bridgeTypes.fixture_size !== "function" ||
        bridgeTypes.fixture_buffer !== "function" ||
        bridgeTypes.profile !== "function" || bridgeTypes.heap !== "object" ||
        bridgeTypes.subarray !== "function") {
      throw new Error("browser host bridge exports unavailable: " + JSON.stringify(bridgeTypes));
    }
    const fixtureValues = await evaluate(cdp, "window.LibFuturoHost.fixtureBytes()");
    if (!Array.isArray(fixtureValues) || fixtureValues.length !== 16512) {
      throw new Error("generated diagnostic fixture is unavailable");
    }
    const fixturePath = path.join(inputDir, "fixture.a78");
    writeFileSync(fixturePath, Buffer.from(fixtureValues), { mode: 0o600 });
    await setInputFile(cdp, fixturePath);
    const loaded = await waitForValue(
      cdp,
      "window.LibFuturoHost.report()",
      value => value.last_selection === "loaded",
      "valid local fixture load",
    );
    if (!loaded.profile_first || loaded.reads !== 1 || loaded.loads !== 1 ||
        loaded.copies !== 1 || loaded.progress !== 0) {
      throw new Error("valid fixture crossed an unexpected load boundary");
    }
    await installFrameCaptureAtProgress(cdp, "__libfuturoTracerOracleFrame", 2);
    await clickTrusted(cdp, "#start-session");
    let started;
    let frame;
    try {
      const observation = await waitForValue(
        cdp,
        "({host:window.LibFuturoHost.report(),frame:window.__libfuturoTracerOracleFrame})",
        value => value.host.started && value.host.audio_graph_rms > 0 &&
          value.frame?.progress === 2,
        "trusted Start and second public frame",
      );
      started = observation.host;
      frame = observation.frame;
    } catch (error) {
      const state = await evaluate(cdp, "window.LibFuturoHost.report()").catch(() => null);
      const diagnostic = state && {
        last_selection: state.last_selection,
        started: state.started,
        progress: state.progress,
        trusted_start: state.trusted_start,
        user_activation: state.user_activation,
        audio_context_state: state.audio_context_state,
        audio_resume_pending: state.audio_resume_pending,
        audio_graph_rms: state.audio_graph_rms,
        runtime_error: state.runtime_error,
        lifecycle: Array.isArray(state.lifecycle) ? state.lifecycle.slice(-4) : [],
      };
      throw new Error(`${error.message}; last host state: ${JSON.stringify(diagnostic)}`);
    }
    if (!frame || frame.progress !== 2 || frame.frame_progress !== 2 ||
        frame.input_buttons !== 0) {
      throw new Error("browser did not capture the second steady frame with released input");
    }
    const expectedRaw = expectedSteadyRawFrame(0x33);
    const rawPass = sameArray(frame.raw, expectedRaw);
    const canvasPass = sameArray(frame.canvas, expectedCanvasFrame(expectedRaw));
    const changed = [...expectedRaw];
    changed[0] ^= 1;
    const changedPixelRejected = !sameArray(frame.raw, changed);
    pagePayload.results.tracer = {
      result: "pass",
      profile: packageInfo.profile,
      configuration: packageInfo.configuration,
      api: packageInfo.api_revision,
      raw_index_oracle: rawPass ? "pass" : "fail",
      canvas_oracle: canvasPass ? "pass" : "fail",
      changed_pixel_control: changedPixelRejected ? "rejected" : "accepted",
      start_trusted: started.trusted_start,
      user_activation: started.user_activation,
      audio_rate: started.audio_rate,
      audio_graph_rms: started.audio_graph_rms,
      instance_created: started.instance_created,
      load_called: started.loads,
      progress: frame.progress,
      frame_progress: frame.frame_progress,
      input_buttons: frame.input_buttons,
    };
    if (!rawPass || !canvasPass || !changedPixelRejected) {
      const mismatch = (actual, expected) => {
        const first = Array.isArray(actual) && Array.isArray(expected)
          ? actual.findIndex((value, index) => value !== expected[index])
          : -1;
        return {
          actual_length: Array.isArray(actual) ? actual.length : null,
          expected_length: Array.isArray(expected) ? expected.length : null,
          first_index: first,
          actual_value: first >= 0 ? actual[first] : null,
          expected_value: first >= 0 ? expected[first] : null,
        };
      };
      throw new Error(`browser output did not match the frozen fixture oracle (${JSON.stringify({
        raw: rawPass,
        canvas: canvasPass,
        changed_pixel_rejected: changedPixelRejected,
        raw_mismatch: mismatch(frame.raw, expectedRaw),
        canvas_mismatch: mismatch(frame.canvas, expectedCanvasFrame(expectedRaw)),
      })})`);
    }
    return pagePayload;
  } finally {
    rmSync(inputDir, { recursive: true, force: true });
  }
}

async function dispatchKeyboardEvent(cdp, type, key, autoRepeat = false) {
  const codes = {
    ArrowUp: { code: "ArrowUp", windowsVirtualKeyCode: 38 },
    ArrowDown: { code: "ArrowDown", windowsVirtualKeyCode: 40 },
    ArrowLeft: { code: "ArrowLeft", windowsVirtualKeyCode: 37 },
    ArrowRight: { code: "ArrowRight", windowsVirtualKeyCode: 39 },
    " ": { code: "Space", windowsVirtualKeyCode: 32 },
  };
  const mapped = codes[key];
  if (!mapped) throw new Error("input test requested an unsupported key");
  await cdp.send("Input.dispatchKeyEvent", {
    type,
    key,
    code: mapped.code,
    windowsVirtualKeyCode: mapped.windowsVirtualKeyCode,
    autoRepeat,
  });
}

async function waitForInputSample(cdp, buttons, label) {
  return waitForValue(
    cdp,
    "window.LibFuturoHost.report()",
    value => Array.isArray(value.input_samples) && value.input_samples.length > 0 &&
      value.input_samples.at(-1) === buttons,
    label,
    5_000,
  );
}

async function runHostInput(cdp, browserCdp, browserPort, targetId,
                            packageInfo, pagePayload, evidenceDir) {
  const inputDir = mkdtempSync(path.join(evidenceDir, "host-input-fixture-"));
  try {
    const fixtureValues = await evaluate(cdp, "window.LibFuturoHost.fixtureBytes()");
    if (!Array.isArray(fixtureValues) || fixtureValues.length !== 16512) {
      throw new Error("generated diagnostic fixture is unavailable for input checks");
    }
    const fixturePath = path.join(inputDir, "fixture.a78");
    writeFileSync(fixturePath, Buffer.from(fixtureValues), { mode: 0o600 });
    await setInputFile(cdp, fixturePath);
    const loaded = await waitForValue(
      cdp,
      "window.LibFuturoHost.report()",
      value => value.last_selection === "loaded",
      "input scenario fixture load",
    );
    if (loaded.progress !== 0 || loaded.loads !== 1 || loaded.copies !== 1) {
      throw new Error("input scenario crossed an unexpected public load boundary");
    }
    await clickTrusted(cdp, "#start-session");
    await waitForValue(
      cdp,
      "window.LibFuturoHost.report()",
      value => value.started && value.progress >= 1,
      "trusted Start and first public frame",
    );
    await delay(120);
    const scheduled = await evaluate(cdp, "window.LibFuturoHost.report()");
    if (scheduled.progress < 3) {
      throw new Error(`rational profile scheduler did not advance one frame per due callback; progress=${scheduled.progress}`);
    }
    const schedulerProbe = await evaluate(cdp, "window.LibFuturoHost.schedulerProbe()");
    if (!schedulerProbe || schedulerProbe.advances !== 3 ||
        schedulerProbe.maxConcurrent !== 1 ||
        schedulerProbe.sixty_hz_advances !== 60 ||
        JSON.stringify(schedulerProbe.due) !== JSON.stringify([true, false, true, false, true]) ||
        schedulerProbe.delayed_once !== true || schedulerProbe.delayed_next_due !== false ||
        schedulerProbe.reentrant_rejected !== true) {
      throw new Error("deterministic rational scheduler probe failed due, delayed, or overlap controls");
    }

    const focusedCanvas = await evaluate(cdp,
      "document.activeElement === document.querySelector('#playfield')");
    if (!focusedCanvas) throw new Error("trusted Start did not focus the playfield");
    const keys = [
      ["ArrowUp", 0x10], ["ArrowDown", 0x20], ["ArrowLeft", 0x40],
      ["ArrowRight", 0x80], [" ", 0x01],
    ];
    const inputSamples = [];
    for (const [key, buttons] of keys) {
      await dispatchKeyboardEvent(cdp, "keyDown", key);
      const pressed = await waitForInputSample(cdp, buttons, `${key} pressed input sample`);
      inputSamples.push(pressed.input_samples.at(-1));
      await dispatchKeyboardEvent(cdp, "keyUp", key);
      const released = await waitForInputSample(cdp, 0, `${key} released input sample`);
      inputSamples.push(released.input_samples.at(-1));
    }
    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowUp");
    await waitForInputSample(cdp, 0x10, "combined input setup");
    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowRight");
    await waitForInputSample(cdp, 0x90, "combined directional input");
    const beforeRepeat = await evaluate(cdp, "window.LibFuturoHost.report()");
    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowUp", true);
    const afterRepeat = await evaluate(cdp, "window.LibFuturoHost.report()");
    const repeatIgnored = afterRepeat.input_transition_calls === beforeRepeat.input_transition_calls;
    await dispatchKeyboardEvent(cdp, "keyUp", "ArrowUp");
    const releasedOne = await waitForInputSample(cdp, 0x80, "combined key release");
    await dispatchKeyboardEvent(cdp, "keyUp", "ArrowRight");
    await waitForInputSample(cdp, 0, "combined input fully released");

    const scrollProbe = await evaluate(cdp, `(() => {
      const root = document.documentElement;
      const body = document.body;
      const original = [root.style.minHeight, body.style.minHeight];
      root.style.minHeight = "200vh";
      body.style.minHeight = "200vh";
      window.scrollTo(0, 100);
      return { y: scrollY, original };
    })()`);
    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowDown");
    await waitForInputSample(cdp, 0x20, "repeat-scroll prevention input setup");
    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowDown", true);
    await delay(100);
    const scrollAfterRepeat = await evaluate(cdp, "scrollY");
    const repeatDefaultPrevented = scrollAfterRepeat === scrollProbe.y;
    await dispatchKeyboardEvent(cdp, "keyUp", "ArrowDown");
    await waitForInputSample(cdp, 0, "repeat-scroll prevention input release");
    await evaluate(cdp, `(() => {
      document.documentElement.style.minHeight = ${JSON.stringify(scrollProbe.original[0])};
      document.body.style.minHeight = ${JSON.stringify(scrollProbe.original[1])};
      window.scrollTo(0, 0);
    })()`);

    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowDown");
    await waitForInputSample(cdp, 0x20, "focus-loss input setup");
    await evaluate(cdp, "document.querySelector('#playfield').blur()");
    const focusedClear = await waitForInputSample(cdp, 0, "playfield focus-loss clearing");
    await evaluate(cdp, "document.querySelector('#playfield').focus()");
    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowLeft");
    await waitForInputSample(cdp, 0x40, "hidden input setup");

    const protocolResponse = await fetch(`http://127.0.0.1:${browserPort}/json/protocol`, {
      signal: AbortSignal.timeout(5_000),
    });
    if (!protocolResponse.ok) throw new Error("pinned browser protocol metadata is unavailable");
    const protocol = await protocolResponse.json();
    const browserDomain = protocol.domains?.find(domain => domain.domain === "Browser");
    const commands = new Set((browserDomain?.commands ?? []).map(command => command.name));
    if (!commands.has("getWindowForTarget") || !commands.has("setWindowBounds")) {
      throw new Error("pinned browser lacks window minimize/restore controls");
    }
    const windowInfo = await browserCdp.send("Browser.getWindowForTarget", { targetId });
    let minimized;
    let restored;
    try {
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "minimized" },
      });
      minimized = await waitForValue(
        cdp,
        "window.LibFuturoHost.report()",
        value => value.document_hidden && value.paused && value.input_buttons === 0 &&
          value.visibility_events.includes("hidden"),
        "actual browser minimize, pause and held-input clearing",
      );
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "normal" },
      });
      restored = await waitForValue(
        cdp,
        "window.LibFuturoHost.report()",
        value => !value.document_hidden && value.paused &&
          value.visibility_events.includes("visible"),
        "actual browser restore without automatic session resume",
      );
    } finally {
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "normal" },
      }).catch(() => {});
    }
    await delay(120);
    const settled = await evaluate(cdp, "window.LibFuturoHost.report()");
    const input = {
      result: "pass",
      profile: packageInfo.profile,
      configuration: packageInfo.configuration,
      profile_cadence: scheduled.progress >= 3,
      frames_after_start: scheduled.progress - 1,
      scheduler_probe: schedulerProbe.advances === 3 && schedulerProbe.maxConcurrent === 1,
      scheduler_60hz_exact: schedulerProbe.sixty_hz_advances === 60,
      scheduler_no_catch_up: schedulerProbe.delayed_once && !schedulerProbe.delayed_next_due,
      scheduler_reentrant_rejected: schedulerProbe.reentrant_rejected,
      focused_canvas: focusedCanvas,
      all_five_bits: JSON.stringify(inputSamples) === JSON.stringify([0x10, 0, 0x20, 0, 0x40, 0, 0x80, 0, 1, 0]),
      combined_input: releasedOne.input_samples.at(-1) === 0x80,
      repeat_ignored: repeatIgnored,
      repeat_default_prevented: repeatDefaultPrevented,
      keyup_release: releasedOne.input_samples.at(-1) === 0x80,
      focus_loss_clear: focusedClear.input_buttons === 0,
      minimized_hidden: minimized.document_hidden === true,
      hidden_clear: minimized.input_buttons === 0,
      restored_visible: restored.document_hidden === false && restored.paused === true,
      no_hidden_catch_up: settled.progress === minimized.progress && settled.paused === true,
    };
    pagePayload.results.input = input;
    return pagePayload;
  } finally {
    rmSync(inputDir, { recursive: true, force: true });
  }
}

async function runHostInputAudio(cdp, packageInfo, pagePayload, evidenceDir) {
  const inputDir = mkdtempSync(path.join(evidenceDir, "host-audio-fixture-"));
  try {
    const fixtureValues = await evaluate(cdp, "window.LibFuturoHost.fixtureBytes()");
    if (!Array.isArray(fixtureValues) || fixtureValues.length !== 16512) {
      throw new Error("generated diagnostic fixture is unavailable for audio checks");
    }
    const fixturePath = path.join(inputDir, "fixture.a78");
    writeFileSync(fixturePath, Buffer.from(fixtureValues), { mode: 0o600 });
    await setInputFile(cdp, fixturePath);
    const loaded = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.last_selection === "loaded", "audio scenario fixture load");
    if (loaded.progress !== 0 || loaded.loads !== 1 || loaded.copies !== 1) {
      throw new Error("audio scenario crossed an unexpected public load boundary");
    }
    if (loaded.audio_context_state !== "none" || loaded.audio_context_creations !== 0) {
      throw new Error("AudioContext was created before trusted Start");
    }
    const audioOracleProbe = await evaluate(cdp, "window.LibFuturoHost.audioOracleProbe()");
    if (!audioOracleProbe || audioOracleProbe.startup_count_valid !== true ||
        audioOracleProbe.changed_startup_count_rejected !== true ||
        audioOracleProbe.steady_800_valid !== true || audioOracleProbe.steady_801_valid !== true ||
        audioOracleProbe.changed_steady_count_rejected !== true) {
      throw new Error("changed PCM sample-count expectation was not rejected");
    }
    const failureHookArmed = await evaluate(cdp,
      "window.LibFuturoHost.failNextAudioStartForTest()");
    if (failureHookArmed !== true) throw new Error("audio Start failure probe could not be armed");
    await clickTrusted(cdp, "#start-session");
    const failedStart = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => !value.started && value.lifecycle.includes("start-failed") &&
        value.audio_context_state === "suspended",
      "failed Start drains audio and suspends its context", 5_000);
    const failedStartStatus = await evaluate(cdp,
      "document.querySelector('#status')?.textContent");
    const failedStartCleanup = failedStart.audio_queue_frames === 0 &&
      failedStart.audio_queue_samples === 0 && failedStart.audio_sources_stopped > 0;
    if (!failedStartCleanup) throw new Error("failed Start retained a queued audio source");

    await clickTrusted(cdp, "#start-session");
    await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.started && value.progress >= 16 && value.audio_frames_produced >= 16,
      "trusted Start retry and frozen startup/steady PCM sequence", 10_000);
    await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.audio_graph_rms > 0 && value.audio_active,
      "active browser audio graph after verified PCM frames", 10_000);
    const running = await evaluate(cdp, "window.LibFuturoHost.report()");
    const expectedCounts = [54, 801, 801, 800, 801, 800, 801, 800, 801, 800,
      801, 801, 800, 801, 800];
    const observedCounts = running.audio_buffer_history.slice(0, expectedCounts.length)
      .map(frame => frame.length);
    const oracleCounts = JSON.stringify(observedCounts) === JSON.stringify(expectedCounts);
    const monoBuffers = running.audio_buffer_history.length >= 16 &&
      running.audio_buffer_history.every(frame => frame.sample_rate === 48000 &&
        frame.channels === 1 && frame.length >= 54 && frame.length <= 801);
    const oraclePcm = running.audio_oracle_frames_verified >= 16 &&
      running.audio_oracle_last_valid === true;
    const queueBounded = running.audio_queue_peak_frames <= 4 &&
      running.audio_queue_peak_samples <= 3204 &&
      running.audio_queue_frames <= 4 && running.audio_queue_samples <= 3204;
    const graphActive = running.audio_graph_rms > 0 && running.audio_active === true;

    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowUp");
    await waitForInputSample(cdp, 0x10, "audio interruption held-input setup");
    const beforeSuspend = await evaluate(cdp, "window.LibFuturoHost.report()");
    await evaluate(cdp, "window.LibFuturoHost.audioContext().suspend()");
    const suspended = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.paused && value.audio_context_state === "suspended" &&
        value.input_buttons === 0 && value.audio_queue_frames === 0,
      "audio suspension pauses guest and retires queued audio", 5_000);
    const suspensionRetired = suspended.audio_sources_stopped > beforeSuspend.audio_sources_stopped &&
      suspended.audio_queue_samples === 0;
    await delay(120);
    const stillSuspended = await evaluate(cdp, "window.LibFuturoHost.report()");
    const noAutoResume = stillSuspended.paused && stillSuspended.progress === suspended.progress &&
      stillSuspended.audio_context_state === "suspended";
    await cdp.send("Page.bringToFront");
    await waitForValue(cdp, "document.hasFocus()", value => value === true,
      "audio resume page focus", 3_000);
    await evaluate(cdp, "document.querySelector('#start-session').focus()");
    if (await evaluate(cdp, "document.activeElement.id === 'start-session'") !== true) {
      throw new Error("Resume control could not receive focus after audio suspension");
    }
    const resumeFailureHookArmed = await evaluate(cdp,
      "window.LibFuturoHost.failNextAudioResumeForTest()");
    if (resumeFailureHookArmed !== true) throw new Error("audio Resume failure probe could not be armed");
    await clickTrusted(cdp, "#start-session");
    const failedResume = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.started && value.paused && value.audio_context_state === "suspended" &&
        value.lifecycle.includes("resume-failed"),
      "failed Resume preserves the existing paused session", 5_000);
    const failedResumeStatus = await evaluate(cdp,
      "document.querySelector('#status')?.textContent");
    const resumeFailurePreserved = failedResume.progress === stillSuspended.progress &&
      failedResume.advances === stillSuspended.advances &&
      failedResume.started === true && failedResume.paused === true;
    if (!resumeFailurePreserved) {
      throw new Error("failed Resume changed guest progress or discarded the paused session");
    }
    await cdp.send("Page.bringToFront");
    await waitForValue(cdp, "document.hasFocus()", value => value === true,
      "page focus before retrying Resume", 3_000);
    await evaluate(cdp, "document.querySelector('#start-session').focus()");
    if (await evaluate(cdp, "document.activeElement.id === 'start-session'") !== true) {
      throw new Error("Resume control could not regain focus after a failed Resume");
    }
    await tapTrusted(cdp, "#start-session");
    let resumed;
    try {
      resumed = await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => !value.paused && value.audio_context_state === "running" &&
          value.progress > stillSuspended.progress,
        "explicit trusted Resume and continued guest work", 5_000);
    } catch (error) {
      const diagnostic = await evaluate(cdp, `(() => {
        const value = window.LibFuturoHost.report();
        return {
          resume_button_disabled: document.querySelector("#start-session")?.disabled,
          resume_button_text: document.querySelector("#start-session")?.textContent,
          active_element: document.activeElement?.id,
          page_focused: document.hasFocus(),
          status: document.querySelector("#status")?.textContent,
          activation_active: navigator.userActivation?.isActive,
          start_attempts: value.start_attempts,
          audio_resume_pending: value.audio_resume_pending,
          started: value.started,
          paused: value.paused,
          context: value.audio_context_state,
          progress: value.progress,
          queue_frames: value.audio_queue_frames,
          runtime_error: value.runtime_error,
          lifecycle: value.lifecycle.slice(-3),
          audio_frames_produced: value.audio_frames_produced,
        };
      })()`);
      throw new Error(`${error.message}; resume state=${JSON.stringify(diagnostic)}`);
    }
    const audio = {
      result: "pass",
      profile: packageInfo.profile,
      configuration: packageInfo.configuration,
      trusted_start: running.trusted_start,
      user_activation: running.user_activation,
      no_context_before_start: loaded.audio_context_state === "none" &&
        loaded.audio_context_creations === 0,
      single_context_on_resume: running.audio_context_creations === 1 &&
        resumed.audio_context_creations === 1,
      failed_start_cleanup: failedStartCleanup &&
        failedStart.audio_context_state === "suspended",
      failed_start_error: failedStartStatus ===
        "This session could not start. Select Start session to try again.",
      failed_start_retry: running.progress >= 16 && running.audio_frames_produced >= 16,
      resume_failure_preserved: resumeFailurePreserved,
      resume_failure_error: failedResumeStatus ===
        "This session could not resume. Select Resume session to try again.",
      resume_failure_retry: resumed.progress > stillSuspended.progress &&
        !resumed.paused && resumed.audio_context_state === "running",
      audio_rate_48khz: running.audio_rate === 48000,
      mono_buffers: monoBuffers,
      oracle_counts: oracleCounts,
      oracle_pcm_validation: oraclePcm,
      changed_sample_control_rejected: audioOracleProbe.changed_startup_count_rejected &&
        audioOracleProbe.changed_steady_count_rejected,
      queue_bounded: queueBounded,
      queue_peak_frames: running.audio_queue_peak_frames,
      queue_peak_samples: running.audio_queue_peak_samples,
      graph_active: graphActive,
      suspension_paused: suspended.paused === true,
      suspension_cleared_input: suspended.input_buttons === 0,
      suspension_retired_sources: suspensionRetired,
      no_auto_resume: noAutoResume,
      explicit_resume_advanced: resumed.progress > stillSuspended.progress,
    };
    pagePayload.results.audio = audio;
    return pagePayload;
  } finally {
    rmSync(inputDir, { recursive: true, force: true });
  }
}

async function runHostUi(cdp, browserCdp, targetId, packageInfo, pagePayload, evidenceDir) {
  const inputDir = mkdtempSync(path.join(evidenceDir, "host-ui-fixture-"));
  const statusText = selector => `document.querySelector(${JSON.stringify(selector)})?.textContent`;
  const fileError = "This A78 file could not be loaded. Choose a non-empty .a78 file within the 1,048,704-byte limit that the selected profile supports, then try again.";
  const runtimeError = "This session could not continue. Select Stop session to end it, then choose the A78 file again to start a new session. Stopping discards in-memory battery changes.";
  try {
    const fixtureValues = await evaluate(cdp, "window.LibFuturoHost.fixtureBytes()");
    if (!Array.isArray(fixtureValues) || fixtureValues.length !== 16512) {
      throw new Error("generated diagnostic fixture is unavailable for UI checks");
    }
    const fixturePath = path.join(inputDir, "private-fixture-name.a78");
    const emptyPath = path.join(inputDir, "private-empty-name.a78");
    const oversizedPath = path.join(inputDir, "private-oversized-name.a78");
    const malformedPath = path.join(inputDir, "private-malformed-name.a78");
    writeFileSync(fixturePath, Buffer.from(fixtureValues), { mode: 0o600 });
    writeFileSync(emptyPath, Buffer.alloc(0), { mode: 0o600 });
    writeFileSync(oversizedPath, Buffer.alloc(1_048_705), { mode: 0o600 });
    writeFileSync(malformedPath, Buffer.from([0x01, 0x02, 0x03, 0x04]), { mode: 0o600 });

    const initial = await evaluate(cdp, `(() => {
      const $ = selector => document.querySelector(selector);
      return {
        heading: $("h1")?.textContent,
        emptyHeading: $("#empty-state-heading")?.textContent,
        emptyCopy: $("#empty-state-copy")?.textContent,
        emptyHidden: $("#empty-state")?.hidden,
        status: $("#status")?.textContent,
        statusRole: $("#status")?.getAttribute("role"),
        statusLive: $("#status")?.getAttribute("aria-live"),
        statusAtomic: $("#status")?.getAttribute("aria-atomic"),
        fileLabel: $("label[for=content-file]")?.textContent,
        fileAccept: $("#content-file")?.getAttribute("accept"),
        labels: [$("#start-session")?.textContent,$("#pause-session")?.textContent,$("#stop-session")?.textContent],
        controlsBeforeStatus: $("#session-controls").compareDocumentPosition($("#status")) & Node.DOCUMENT_POSITION_FOLLOWING,
        statusBeforeInstructions: $("#status").compareDocumentPosition($("#instructions")) & Node.DOCUMENT_POSITION_FOLLOWING,
        instructions: $("#instructions")?.textContent,
        canvasName: $("#playfield")?.getAttribute("aria-label"),
        canvasDescription: $("#playfield")?.getAttribute("aria-describedby"),
        canvasFallback: $("#playfield")?.textContent,
        canvasSize: [$("#playfield")?.width,$("#playfield")?.height],
        inputDisabled: $("#content-file")?.disabled,
        startDisabled: $("#start-session")?.disabled,
        pauseDisabled: $("#pause-session")?.disabled,
        stopDisabled: $("#stop-session")?.disabled,
        warningHidden: $("#stop-warning")?.hidden,
        blank: window.LibFuturoHost.canvasBlank(),
      };
    })()`);
    const initialEmpty = initial.heading === "Atari 7800 session" &&
      initial.emptyHeading === "No game loaded" && initial.emptyHidden === false &&
      initial.emptyCopy === "Choose a local .a78 file to begin. The host uses it for this session only; it does not upload or save the file or battery media." &&
      initial.status === "";
    const initialControls = initial.inputDisabled === false && initial.startDisabled === true &&
      initial.pauseDisabled === true && initial.stopDisabled === true &&
      initial.warningHidden === true && initial.blank === true;
    const semanticContract = initial.statusRole === "status" && initial.statusLive === "polite" &&
      initial.statusAtomic === "true" && initial.fileLabel === "Choose a local .a78 file" &&
      initial.fileAccept === ".a78" &&
      JSON.stringify(initial.labels) === JSON.stringify(["Start session", "Pause session", "Stop session"]) &&
      initial.controlsBeforeStatus === 4 && initial.statusBeforeInstructions === 4 &&
      initial.instructions === "Focus the playfield, then use Arrow keys to move and Space for Button 1." &&
      initial.canvasName === "Atari 7800 playfield" && initial.canvasDescription === "instructions" &&
      initial.canvasFallback === "Canvas output is unavailable in this browser." &&
      JSON.stringify(initial.canvasSize) === JSON.stringify([320, 242]);

    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 320, height: 820, deviceScaleFactor: 1, mobile: false,
    });
    const narrow = await evaluate(cdp, `(() => {
      const main = document.querySelector("main");
      const canvas = document.querySelector("#playfield");
      const controls = document.querySelector("#file-controls");
      const button = document.querySelector("#start-session");
      const file = document.querySelector("#content-file");
      return {
        viewport: innerWidth,
        rootNoOverflow: document.documentElement.scrollWidth <= document.documentElement.clientWidth,
        mainMax: getComputedStyle(main).maxWidth,
        mainWidth: main.getBoundingClientRect().width,
        canvasWidth: canvas.getBoundingClientRect().width,
        canvasHeight: canvas.getBoundingClientRect().height,
        canvasRatio: canvas.getBoundingClientRect().width / canvas.getBoundingClientRect().height,
        pixelated: getComputedStyle(canvas).imageRendering,
        buttonHeight: button.getBoundingClientRect().height,
        fileHeight: file.getBoundingClientRect().height,
        controlsWrap: getComputedStyle(controls).flexWrap,
      };
    })()`);
    const layoutContract = narrow.viewport === 320 && narrow.rootNoOverflow === true &&
      narrow.mainMax === "640px" && narrow.mainWidth <= 640 && narrow.canvasWidth <= 640 &&
      Math.abs(narrow.canvasRatio - 320 / 242) < 0.02 && narrow.pixelated === "pixelated" &&
      narrow.buttonHeight >= 44 && narrow.fileHeight >= 44 && narrow.controlsWrap === "wrap";

    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-color-scheme", value: "light" }],
    });
    await setInputFile(cdp, emptyPath);
    const emptyRejectedState = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.last_selection === "empty" && !value.file_read_pending,
      "zero-byte file rejection");
    const emptyRejected = emptyRejectedState.progress === 0 && emptyRejectedState.advances === 0 &&
      await evaluate(cdp, `${statusText("#status")} === ${JSON.stringify(fileError)} && window.LibFuturoHost.canvasBlank()`);

    await setInputFile(cdp, oversizedPath);
    const oversizedState = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.last_selection === "oversized" && !value.file_read_pending,
      "oversized file rejection");
    const oversizeRejected = oversizedState.reads === emptyRejectedState.reads &&
      oversizedState.wasm_copy_count === emptyRejectedState.wasm_copy_count &&
      oversizedState.progress === 0 && oversizedState.advances === 0 &&
      await evaluate(cdp, `${statusText("#status")} === ${JSON.stringify(fileError)} && window.LibFuturoHost.canvasBlank()`);

    await setInputFile(cdp, malformedPath);
    const malformed = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.last_selection === "load-refused" && !value.file_read_pending,
      "malformed file rejection");
    const malformedRejected = malformed.progress === 0 && malformed.advances === 0 &&
      await evaluate(cdp, `${statusText("#status")} === ${JSON.stringify(fileError)} && window.LibFuturoHost.canvasBlank()`);
    const privacyClean = await evaluate(cdp,
      `(() => { const text = document.body.innerText + document.querySelector("#status").textContent + document.querySelector("#stop-warning").textContent; return !["private-fixture-name","private-empty-name","private-oversized-name","private-malformed-name","file://","/tmp/","/work/"].some(value => text.includes(value)); })()`);

    const gateReady = await evaluate(cdp, "window.LibFuturoHost.holdNextFileRead()");
    if (gateReady !== true) throw new Error("file-read UI seam was not available");
    await setInputFile(cdp, fixturePath);
    const checking = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.file_read_pending, "checking-file state");
    const checkingState = await evaluate(cdp, `(() => ({status:document.querySelector("#status").textContent,file:document.querySelector("#content-file").disabled,start:document.querySelector("#start-session").disabled,pause:document.querySelector("#pause-session").disabled,stop:document.querySelector("#stop-session").disabled,warning:document.querySelector("#stop-warning").hidden}))()`);
    const checkingPass = checkingState.status === "Checking file…" && checkingState.file &&
      checkingState.start && checkingState.pause && checkingState.stop && checkingState.warning;
    if (await evaluate(cdp, "window.LibFuturoHost.releaseFileRead()") !== true) {
      throw new Error("checking-file gate could not be released");
    }
    const accepted = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.last_selection === "loaded" && !value.file_read_pending,
      "accepted-content state");
    const acceptedState = await evaluate(cdp, `(() => ({status:document.querySelector("#status").textContent,ready:document.body.dataset.ready,emptyHidden:document.querySelector("#empty-state").hidden,startDisabled:document.querySelector("#start-session").disabled,pauseDisabled:document.querySelector("#pause-session").disabled,stopDisabled:document.querySelector("#stop-session").disabled,warningHidden:document.querySelector("#stop-warning").hidden,warning:document.querySelector("#stop-warning").textContent}))()`);
    const acceptedPass = accepted.progress === 0 && acceptedState.status === "File ready. Select Start session." &&
      acceptedState.ready === "true" && acceptedState.emptyHidden && !acceptedState.startDisabled &&
      acceptedState.pauseDisabled && !acceptedState.stopDisabled && !acceptedState.warningHidden &&
      acceptedState.warning === "Stopping discards in-memory battery changes for this session.";
    const narrowWarningNoOverflow = await evaluate(cdp, `(() => {
      const warning = document.querySelector("#stop-warning").getBoundingClientRect();
      const main = document.querySelector("main").getBoundingClientRect();
      return innerWidth === 320 &&
        document.documentElement.scrollWidth <= document.documentElement.clientWidth &&
        warning.left >= main.left - 1 && warning.right <= main.right + 1;
    })()`);
    const screenshots = [];
    const captureUiScreenshot = async label => {
      const clip = await evaluate(cdp, `(() => {
        const controls = document.querySelector("#session-controls").getBoundingClientRect();
        const top = Math.max(0, controls.top - 8);
        return {
          x: 0,
          y: top,
          width: innerWidth,
          height: Math.min(innerHeight - top, controls.height + 16),
          scale: 1,
        };
      })()`);
      const captured = await cdp.send("Page.captureScreenshot", {
        format: "png", captureBeyondViewport: false, fromSurface: true, clip,
      });
      const filename = `host-ui-${label}.png`;
      const bytes = Buffer.from(captured.data, "base64");
      if (bytes.length === 0) throw new Error(`empty UI screenshot: ${filename}`);
      writeFileSync(path.join(evidenceDir, filename), bytes, { mode: 0o600 });
      screenshots.push(filename);
    };
    await captureUiScreenshot("mobile");

    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 672, height: 900, deviceScaleFactor: 1, mobile: false,
    });
    const warningLayout = await evaluate(cdp, `(() => {
      const stop = document.querySelector("#stop-session").getBoundingClientRect();
      const warning = document.querySelector("#stop-warning");
      const warningBox = warning.getBoundingClientRect();
      const controls = warning.parentElement;
      const controlsBox = controls.getBoundingClientRect();
      const statusStyle = getComputedStyle(document.querySelector("#status"));
      const buttonStyle = getComputedStyle(document.querySelector("button"));
      return {
        besideStop: warningBox.left >= stop.right - 1 &&
          warningBox.top < stop.bottom && warningBox.bottom > stop.top,
        insideControlGroup: warningBox.right <= controlsBox.right + 1 &&
          warningBox.left >= controlsBox.left - 1,
        statusMargin: statusStyle.marginBlockStart,
        buttonPaddingInlineStart: buttonStyle.paddingInlineStart,
        buttonPaddingInlineEnd: buttonStyle.paddingInlineEnd,
      };
    })()`);
    const stopWarningBesideStop = warningLayout.besideStop && warningLayout.insideControlGroup;
    const spacingContract = warningLayout.statusMargin === "8px" &&
      warningLayout.buttonPaddingInlineStart === "8px" &&
      warningLayout.buttonPaddingInlineEnd === "8px";

    const lightColors = await evaluate(cdp, `(() => { const s=getComputedStyle(document.querySelector("#stop-warning")); return [s.color,s.backgroundColor]; })()`);
    const lightWarning = JSON.stringify(lightColors) === JSON.stringify(["rgb(139, 30, 30)", "rgb(252, 232, 230)"]);
    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-color-scheme", value: "dark" }],
    });
    const darkColors = await evaluate(cdp, `(() => { const s=getComputedStyle(document.querySelector("#stop-warning")); return [s.color,s.backgroundColor]; })()`);
    const darkWarning = JSON.stringify(darkColors) === JSON.stringify(["rgb(255, 180, 171)", "rgb(59, 16, 16)"]);
    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-color-scheme", value: "light" }, { name: "forced-colors", value: "active" }],
    });
    const forcedColors = await evaluate(cdp, `(() => { const s=getComputedStyle(document.querySelector("#stop-warning")); return {media:matchMedia("(forced-colors: active)").matches,color:s.color,background:s.backgroundColor,border:s.borderTopWidth}; })()`);
    const forcedColorWarning = forcedColors.media && forcedColors.color !== "rgb(139, 30, 30)" &&
      forcedColors.background !== "rgb(252, 232, 230)" && forcedColors.border === "1px";
    await cdp.send("Emulation.setEmulatedMedia", { features: [] });

    await evaluate(cdp, "document.querySelector('#content-file').focus()");
    await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Tab", code: "Tab", windowsVirtualKeyCode: 9 });
    await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Tab", code: "Tab", windowsVirtualKeyCode: 9 });
    const focus = await evaluate(cdp, `(() => { const e=document.activeElement; const s=getComputedStyle(e); return {id:e.id,visible:e.matches(":focus-visible"),width:s.outlineWidth,style:s.outlineStyle}; })()`);
    const keyboardFocus = focus.id === "start-session" && focus.visible && focus.width === "3px" && focus.style === "solid";

    await clickTrusted(cdp, "#start-session");
    const running = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.started && !value.paused && value.progress >= 16 && value.audio_context_state === "running",
      "running presentation state");
    const runningState = await evaluate(cdp, `(() => ({status:document.querySelector("#status").textContent,startDisabled:document.querySelector("#start-session").disabled,pauseDisabled:document.querySelector("#pause-session").disabled,stopDisabled:document.querySelector("#stop-session").disabled,warningHidden:document.querySelector("#stop-warning").hidden}))()`);
    const runningPass = runningState.status === "Running." && runningState.startDisabled &&
      !runningState.pauseDisabled && !runningState.stopDisabled && !runningState.warningHidden;
    await captureUiScreenshot("desktop");

    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowLeft");
    const held = await waitForInputSample(cdp, 0x40, "minimized UI input setup");
    const windowInfo = await browserCdp.send("Browser.getWindowForTarget", { targetId });
    let hidden;
    let restored;
    try {
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId, bounds: { windowState: "minimized" },
      });
      hidden = await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => value.document_hidden && value.paused && value.input_buttons === 0 &&
          value.audio_queue_frames === 0 && value.visibility_events.includes("hidden"),
        "actual minimized UI interruption");
      hidden.status = await evaluate(cdp, statusText("#status"));
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId, bounds: { windowState: "normal" },
      });
      restored = await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => !value.document_hidden && value.paused && value.visibility_events.includes("visible"),
        "actual restored UI pause");
    } finally {
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId, bounds: { windowState: "normal" },
      }).catch(() => {});
    }
    await delay(120);
    const restoredSettled = await evaluate(cdp, "window.LibFuturoHost.report()");
    restored.status = await evaluate(cdp, statusText("#status"));
    const minimizedHidden = hidden.document_hidden && hidden.input_buttons === 0 &&
      hidden.audio_sources_stopped > held.audio_sources_stopped && hidden.audio_queue_samples === 0;
    const hiddenStatus = hidden.status === "Session paused because this page was hidden. Return and select Resume session to continue.";
    const restoredPaused = restored.document_hidden === false && restored.paused === true;
    const restoredStatus = restored.status === "Paused. Select Resume session to continue.";
    const noAutoResume = restoredSettled.paused && restoredSettled.progress === restored.progress;
    await clickTrusted(cdp, "#start-session");
    const resumed = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => !value.paused && value.progress > restoredSettled.progress && value.audio_context_state === "running",
      "explicit UI resume");
    const explicitResume = resumed.progress > restoredSettled.progress && !resumed.paused;

    await clickTrusted(cdp, "#pause-session");
    const paused = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.paused && value.input_buttons === 0,
      "Pause session action");
    const pausedText = await evaluate(cdp, statusText("#status"));
    const pausedControls = await evaluate(cdp, `(() => ({start:document.querySelector("#start-session").textContent,startDisabled:document.querySelector("#start-session").disabled,pauseDisabled:document.querySelector("#pause-session").disabled,stopDisabled:document.querySelector("#stop-session").disabled}))()`);
    const pausedState = paused.paused && pausedText === "Paused. Select Resume session to continue." &&
      pausedControls.start === "Resume session" && !pausedControls.startDisabled &&
      pausedControls.pauseDisabled && !pausedControls.stopDisabled;

    await clickTrusted(cdp, "#start-session");
    const audioResumed = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => !value.paused && value.audio_context_state === "running" && value.progress > paused.progress,
      "resume before audio-interruption UI check");
    const beforeAudioSuspend = await suspendAudioWithQueuedSource(cdp);
    const audioPaused = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.paused && value.audio_context_state === "suspended" && value.input_buttons === 0 && value.audio_queue_frames === 0,
      "audio interruption presentation");
    const audioText = await evaluate(cdp, statusText("#status"));
    await delay(120);
    const audioStillPaused = await evaluate(cdp, "window.LibFuturoHost.report()");
    const audioNoAutoResume = audioStillPaused.paused && audioStillPaused.progress === audioPaused.progress &&
      audioStillPaused.audio_context_state === "suspended";
    const audioInterruptionEvent = audioPaused.lifecycle.includes("audio-interrupted");
    const audioInterrupted = audioText === "Audio was interrupted. Select Resume session to restart audio and continue." &&
      audioPaused.audio_sources_stopped > beforeAudioSuspend.audio_sources_stopped &&
      audioPaused.audio_queue_samples === 0 && audioInterruptionEvent;
    await clickTrusted(cdp, "#start-session");
    const afterAudioResume = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => !value.paused && value.audio_context_state === "running" && value.progress > audioStillPaused.progress,
      "explicit audio resume");
    const audioExplicitResume = afterAudioResume.progress > audioStillPaused.progress;

    const injected = await evaluate(cdp, "window.LibFuturoHost.failNextFrameForTest()");
    if (!injected) throw new Error("runtime-error UI seam was not available while running");
    const errored = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.runtime_error && value.paused,
      "runtime-error state");
    const runtimeUi = await evaluate(cdp, `(() => ({status:document.querySelector("#status").textContent,startDisabled:document.querySelector("#start-session").disabled,pauseDisabled:document.querySelector("#pause-session").disabled,stopDisabled:document.querySelector("#stop-session").disabled,warningHidden:document.querySelector("#stop-warning").hidden,progress:window.LibFuturoHost.report().progress}))()`);
    const runtimeErrorState = errored.progress >= afterAudioResume.progress && runtimeUi.status === runtimeError &&
      runtimeUi.startDisabled && runtimeUi.pauseDisabled && !runtimeUi.stopDisabled && !runtimeUi.warningHidden &&
      runtimeUi.progress === errored.progress;
    const statusAndBody = await evaluate(cdp,
      `(() => { const page=document.body.innerText; const status=document.querySelector("#status").textContent; return {page,status}; })()`);
    const privacyAfterRuntime = !["private-fixture-name","private-empty-name","private-oversized-name","private-malformed-name","file://","/tmp/","/work/"].some(value => (statusAndBody.page + statusAndBody.status).includes(value));

    await clickTrusted(cdp, "#stop-session");
    const stopped = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.stopped && value.destroy_calls === errored.destroy_calls + 1,
      "Stop action from runtime error");
    const stoppedUi = await evaluate(cdp, `(() => ({status:document.querySelector("#status").textContent,fileDisabled:document.querySelector("#content-file").disabled,fileValue:document.querySelector("#content-file").value,startDisabled:document.querySelector("#start-session").disabled,pauseDisabled:document.querySelector("#pause-session").disabled,stopDisabled:document.querySelector("#stop-session").disabled,warningHidden:document.querySelector("#stop-warning").hidden,emptyHidden:document.querySelector("#empty-state").hidden,focus:document.activeElement.id,blank:window.LibFuturoHost.canvasBlank()}))()`);
    const stoppedState = stoppedUi.status === "Session stopped. In-memory battery changes were discarded. Choose the A78 file again to start a new session." &&
      stoppedUi.fileDisabled === false && stoppedUi.fileValue === "" && stoppedUi.startDisabled &&
      stoppedUi.pauseDisabled && stoppedUi.stopDisabled && stoppedUi.warningHidden &&
      stoppedUi.emptyHidden && stoppedUi.focus === "content-file" && stoppedUi.blank;

    const ui = {
      result: "pass",
      profile: packageInfo.profile,
      configuration: packageInfo.configuration,
      initial_empty: initialEmpty,
      initial_controls: initialControls,
      semantic_contract: semanticContract,
      layout_contract: layoutContract,
      narrow_warning_no_overflow: narrowWarningNoOverflow,
      stop_warning_beside_stop: stopWarningBesideStop,
      spacing_contract: spacingContract,
      screenshots,
      keyboard_focus: keyboardFocus,
      light_warning: lightWarning,
      dark_warning: darkWarning,
      forced_color_warning: forcedColorWarning,
      checking_state: checkingPass,
      accepted_state: acceptedPass,
      empty_rejected: emptyRejected,
      oversize_rejected: oversizeRejected,
      malformed_rejected: malformedRejected,
      privacy_clean: privacyClean && privacyAfterRuntime,
      running_state: runningPass,
      minimized_hidden: minimizedHidden,
      hidden_status: hiddenStatus,
      restored_paused: restoredPaused,
      restored_status: restoredStatus,
      no_auto_resume: noAutoResume,
      explicit_resume: explicitResume,
      paused_state: pausedState,
      audio_interrupted: audioInterrupted,
      audio_interruption: {
        status_text: audioText,
        context_state_before: beforeAudioSuspend.audio_context_state,
        context_state_after: audioPaused.audio_context_state,
        input_buttons_before: beforeAudioSuspend.input_buttons,
        input_buttons_after: audioPaused.input_buttons,
        queue_frames_before: beforeAudioSuspend.audio_queue_frames,
        queue_frames_after: audioPaused.audio_queue_frames,
        queue_samples_before: beforeAudioSuspend.audio_queue_samples,
        queue_samples_after: audioPaused.audio_queue_samples,
        sources_stopped_before: beforeAudioSuspend.audio_sources_stopped,
        sources_stopped_after: audioPaused.audio_sources_stopped,
        lifecycle_event: audioInterruptionEvent,
      },
      audio_no_auto_resume: audioNoAutoResume,
      audio_explicit_resume: audioExplicitResume,
      runtime_error_state: runtimeErrorState,
      stopped_state: stoppedState,
    };
    pagePayload.results.ui = ui;
    return pagePayload;
  } finally {
    await cdp.send("Emulation.setEmulatedMedia", { features: [] }).catch(() => {});
    await cdp.send("Emulation.clearDeviceMetricsOverride").catch(() => {});
    rmSync(inputDir, { recursive: true, force: true });
  }
}

async function runHostLifecycle(cdp, browserCdp, browserPort, targetId, localOrigin,
                                packageInfo, pagePayload, evidenceDir, bfcacheNotUsed,
                                pagehideReports) {
  const inputDir = mkdtempSync(path.join(evidenceDir, "host-lifecycle-fixture-"));
  try {
    const probeStateExpression = `({complete:document.body?.dataset.complete,result:document.body?.dataset.result,ready:document.body?.dataset.ready === "true",origin:location.origin})`;
    const fixtureValues = await evaluate(cdp, "window.LibFuturoHost.fixtureBytes()");
    if (!Array.isArray(fixtureValues) || fixtureValues.length !== 16512) {
      throw new Error("generated diagnostic fixture is unavailable for lifecycle checks");
    }
    const fixturePath = path.join(inputDir, "fixture.a78");
    writeFileSync(fixturePath, Buffer.from(fixtureValues), { mode: 0o600 });
    await setInputFile(cdp, fixturePath);
    const loaded = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.last_selection === "loaded", "lifecycle fixture load");
    if (loaded.progress !== 0 || loaded.loads !== 1) {
      throw new Error("lifecycle fixture crossed an unexpected public load boundary");
    }
    await clickTrusted(cdp, "#start-session");
    await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.started && value.audio_context_state === "running" && value.progress >= 16,
      "trusted lifecycle Start");

    const protocolResponse = await fetch(`http://127.0.0.1:${browserPort}/json/protocol`, {
      signal: AbortSignal.timeout(5_000),
    });
    if (!protocolResponse.ok) throw new Error("pinned browser protocol metadata is unavailable");
    const protocol = await protocolResponse.json();
    const browserDomain = protocol.domains?.find(domain => domain.domain === "Browser");
    const commands = new Set((browserDomain?.commands ?? []).map(command => command.name));
    if (!commands.has("getWindowForTarget") || !commands.has("setWindowBounds")) {
      throw new Error("pinned browser lacks window minimize/restore controls");
    }
    const windowInfo = await browserCdp.send("Browser.getWindowForTarget", { targetId });
    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowLeft");
    await waitForInputSample(cdp, 0x40, "hidden lifecycle input setup");
    const queuedBeforeMinimize = await waitForValue(cdp, "window.LibFuturoHost.report()",
      value => value.input_buttons === 0x40 && value.audio_queue_frames > 0 &&
        value.audio_queue_samples > 0,
      "nonempty audio queue immediately before lifecycle minimize", 5_000);
    let minimized;
    let restored;
    let hiddenStatus;
    try {
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "minimized" },
      });
      minimized = await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => value.document_hidden && value.paused && value.input_buttons === 0 &&
          value.audio_queue_frames === 0 && value.visibility_events.includes("hidden"),
        "actual minimized lifecycle pause, input clearing and audio retirement");
      hiddenStatus = await evaluate(cdp,
        "document.querySelector('#status').textContent");
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "normal" },
      });
      restored = await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => !value.document_hidden && value.paused &&
          value.visibility_events.includes("visible"),
        "actual restored lifecycle pause without automatic resume");
    } finally {
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "normal" },
      }).catch(() => {});
    }
    await delay(120);
    const settled = await evaluate(cdp, "window.LibFuturoHost.report()");
    const restoredStatus = await evaluate(cdp,
      "document.querySelector('#status').textContent");
    const minimizedAudioRetired = minimized.audio_sources_stopped > queuedBeforeMinimize.audio_sources_stopped &&
      minimized.audio_queue_samples === 0;
    await cdp.send("Page.bringToFront");
    await waitForValue(cdp, "document.hasFocus()", value => value === true,
      "restored browser page focus", 3_000);
    await evaluate(cdp, "document.querySelector('#start-session').focus()");
    if (await evaluate(cdp, "document.activeElement.id === 'start-session'") !== true) {
      throw new Error("Resume control could not receive focus after window restoration");
    }
    await clickTrusted(cdp, "#start-session");
    let resumed;
    try {
      resumed = await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => !value.paused && value.progress > restored.progress &&
          value.audio_context_state === "running", "explicit resume after browser restore", 3_000);
    } catch {
      const failedResume = await evaluate(cdp, `(() => ({host:window.LibFuturoHost.report(),status:document.querySelector("#status").textContent,startDisabled:document.querySelector("#start-session").disabled,startText:document.querySelector("#start-session").textContent,activeElement:document.activeElement?.id}))()`);
      throw new Error("explicit browser-restore resume did not advance: " + JSON.stringify({
        restored_progress: restored.progress,
        started: failedResume.host.started,
        paused: failedResume.host.paused,
        progress: failedResume.host.progress,
        audio_context_state: failedResume.host.audio_context_state,
        status: failedResume.status,
        start_disabled: failedResume.startDisabled,
        start_text: failedResume.startText,
        active_element: failedResume.activeElement,
        user_activation: failedResume.host.user_activation,
        audio_resume_pending: failedResume.host.audio_resume_pending,
        lifecycle: failedResume.host.lifecycle.slice(-4),
      }));
    }

    const stopApiAvailable = await evaluate(cdp,
      "typeof window.LibFuturoHost.stopSession === 'function'");
    let stopDestroysOnce = false;
    let staleCallbackNoCalls = false;
    if (stopApiAvailable) {
      await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => value.frame_callback_pending === true,
        "an outstanding animation callback before Stop");
      const teardown = await evaluate(cdp,
        "(() => { const before = window.LibFuturoHost.report(); const captured = window.LibFuturoHost.captureNextFrameCallback(); const firstStop = window.LibFuturoHost.stopSession(); const secondStop = window.LibFuturoHost.stopSession(); const afterStop = window.LibFuturoHost.report(); window.LibFuturoHost.invokeCapturedStaleFrameCallback(); return {before,captured,firstStop,secondStop,afterStop}; })()");
      const beforeStop = teardown.before;
      const afterStop = teardown.afterStop;
      stopDestroysOnce = teardown.captured === true && teardown.firstStop === true &&
        teardown.secondStop === false && afterStop.stale_callback_captured === true &&
        afterStop.stopped && afterStop.paused &&
        afterStop.input_buttons === 0 && afterStop.audio_queue_frames === 0 &&
        afterStop.destroy_calls === beforeStop.destroy_calls + 1;
      await delay(100);
      const afterStale = await evaluate(cdp, "window.LibFuturoHost.report()");
      staleCallbackNoCalls = afterStale.stale_callback_invoked === true &&
        afterStale.progress === afterStop.progress &&
        afterStale.profile_queries === afterStop.profile_queries &&
        afterStale.copies === afterStop.copies &&
        afterStale.loads === afterStop.loads &&
        afterStale.advances === afterStop.advances &&
        afterStale.input_transition_calls === afterStop.input_transition_calls &&
        afterStale.destroy_calls === afterStop.destroy_calls;

      await setInputFile(cdp, fixturePath);
      const restarted = await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => value.last_selection === "loaded", "fixture reload after Stop");
      if (restarted.progress !== 0 || restarted.loads !== beforeStop.loads + 1) {
        throw new Error("selecting a new file after Stop crossed an unexpected public load boundary");
      }
      await clickTrusted(cdp, "#start-session");
      await waitForValue(cdp, "window.LibFuturoHost.report()",
        value => value.started && !value.paused && value.audio_context_state === "running" &&
          value.progress >= 16, "trusted Start for pagehide scenario");
    }

    await dispatchKeyboardEvent(cdp, "keyDown", "ArrowUp");
    const pagehideHeld = await waitForInputSample(cdp, 0x10, "pagehide input setup");
    const pagehideToken = randomBytes(8).toString("hex");
    await evaluate(cdp,
      `window.addEventListener('pagehide', () => { const host = window.LibFuturoHost.report(); const report = {token:${JSON.stringify(pagehideToken)},paused:host.paused,input_buttons:host.input_buttons,audio_queue_frames:host.audio_queue_frames,audio_queue_samples:host.audio_queue_samples,audio_sources_stopped:host.audio_sources_stopped,lifecycle_pagehide:host.lifecycle.includes('pagehide')}; navigator.sendBeacon(${JSON.stringify(`${localOrigin}/lifecycle-pagehide`)}, new Blob([JSON.stringify(report)], {type:'text/plain'})); }, {once:true})`);
    const sameOriginBefore = await evaluate(cdp, "location.origin");
    await evaluate(cdp,
      `(() => { const link = document.createElement('a'); link.id = 'lifecycle-navigation'; link.href = ${JSON.stringify(`${localOrigin}/next`)}; link.textContent = 'Continue lifecycle check'; link.style.cssText = 'position:fixed;top:4px;left:4px;z-index:9999;padding:8px;background:white;color:black'; document.body.append(link); })()`);
    await clickTrusted(cdp, "#lifecycle-navigation");
    const nextPage = await waitForValue(cdp,
      probeStateExpression,
      value => value?.complete === "true" && value.result === "pass" && value.ready === true,
      "same-origin lifecycle probe destination", 20_000);
    if (nextPage.origin !== sameOriginBefore) {
      throw new Error("pagehide lifecycle probe did not remain same-origin");
    }
    const pagehide = await waitForObservation(
      () => pagehideReports.find(report => report.token === pagehideToken),
      value => value !== undefined,
      "actual pagehide report from the pinned browser",
    );
    const pagehideClean = pagehide.paused === true && pagehide.input_buttons === 0 &&
      pagehide.audio_queue_frames === 0 && pagehide.audio_queue_samples === 0 &&
      pagehide.audio_sources_stopped > pagehideHeld.audio_sources_stopped &&
      pagehide.lifecycle_pagehide === true;
    const history = await cdp.send("Page.getNavigationHistory");
    const previousEntry = history.entries?.[history.currentIndex - 1];
    if (!previousEntry || new URL(previousEntry.url).origin !== sameOriginBefore) {
      throw new Error("same-origin history entry unavailable for the lifecycle BFCache probe");
    }
    await cdp.send("Page.navigateToHistoryEntry", { entryId: previousEntry.id });
    await waitForValue(cdp,
      probeStateExpression,
      value => value?.complete === "true" && value.result === "pass" && value.ready === true,
      "same-origin lifecycle history return", 20_000);
    await delay(100);
    const restoredPage = await evaluate(cdp,
      "({origin:location.origin,host:window.LibFuturoHost.report()})");
    const sameOriginBfcache = restoredPage.origin === sameOriginBefore &&
      sameOriginBefore === new URL(`${localOrigin}/`).origin;
    const bfcachePersisted = restoredPage.host.lifecycle.includes("pagehide-persisted") &&
      restoredPage.host.lifecycle.includes("pageshow-persisted");
    const bfcacheReasons = [...new Set(
      bfcacheNotUsed.flatMap(event => collectBfcacheReasons(event)),
    )].sort();

    pagePayload.results.lifecycle = {
      result: "pass",
      profile: packageInfo.profile,
      configuration: packageInfo.configuration,
      minimized_hidden: minimized.document_hidden === true &&
        minimized.visibility_events.includes("hidden"),
      hidden_input_cleared: minimized.input_buttons === 0,
      hidden_audio_discarded: minimizedAudioRetired,
      audio_retirement: {
        queued_before_hide: queuedBeforeMinimize.audio_queue_frames > 0 &&
          queuedBeforeMinimize.audio_queue_samples > 0,
        queue_frames_before_hide: queuedBeforeMinimize.audio_queue_frames,
        queue_samples_before_hide: queuedBeforeMinimize.audio_queue_samples,
        sources_stopped_before_hide: queuedBeforeMinimize.audio_sources_stopped,
        sources_stopped_after_hide: minimized.audio_sources_stopped,
        source_retired_on_hide: minimizedAudioRetired,
      },
      hidden_status_correct: hiddenStatus ===
        "Session paused because this page was hidden. Return and select Resume session to continue.",
      restored_status_correct: restoredStatus ===
        "Paused. Select Resume session to continue.",
      restored_visible_paused: restored.document_hidden === false && restored.paused === true &&
        restored.visibility_events.includes("visible"),
      no_hidden_catch_up: settled.progress === minimized.progress && settled.paused === true,
      explicit_resume_advanced: resumed.progress > restored.progress && !resumed.paused,
      pagehide_observed: pagehide.lifecycle_pagehide === true,
      pagehide_paused: pagehide.paused === true,
      pagehide_input_cleared: pagehide.input_buttons === 0,
      pagehide_audio_discarded: pagehideClean,
      stop_api_available: stopApiAvailable,
      stop_destroys_once: stopDestroysOnce,
      stale_callback_no_calls: staleCallbackNoCalls,
      same_origin_bfcache: sameOriginBfcache,
      bfcache_persisted: bfcachePersisted,
      bfcache_not_restored_reasons: bfcacheReasons,
      next_page_ready: nextPage.ready === true,
    };
    return pagePayload;
  } finally {
    rmSync(inputDir, { recursive: true, force: true });
  }
}

function readCounters(report) {
  return {
    reads: report.reads,
    wasmCopies: report.wasm_copy_count,
    copies: report.copies,
    loads: report.loads,
    advances: report.advances,
    progress: report.progress,
  };
}

function counterDelta(after, before, key) {
  return after[key] - before[key];
}

async function selectContentFile(cdp, filePath, expectedSelection, label) {
  const before = await evaluate(cdp, "window.LibFuturoHost.report()");
  await setInputFile(cdp, filePath);
  const after = await waitForValue(
    cdp,
    "window.LibFuturoHost.report()",
    value => value.selections === before.selections + 1 &&
      value.last_selection === expectedSelection,
    label,
  );
  return { before, after };
}

function collectBfcacheReasons(value, reasons = []) {
  if (!value || typeof value !== "object") return reasons;
  if (typeof value.reason === "string") reasons.push(value.reason);
  if (Array.isArray(value.notRestoredExplanations)) {
    for (const explanation of value.notRestoredExplanations) {
      if (typeof explanation?.reason === "string") reasons.push(explanation.reason);
    }
  }
  if (Array.isArray(value.children)) {
    for (const child of value.children) collectBfcacheReasons(child, reasons);
  }
  if (value.explanationTree) collectBfcacheReasons(value.explanationTree, reasons);
  return reasons;
}

async function runHostContent(cdp, browserCdp, browserPort, targetId, localOrigin,
                              packageInfo, pagePayload, evidenceDir, requestLog,
                              browserRequestObservations, browserConsoleObservations,
                              browserNetworkErrors, browserConsoleErrors, protocolErrors,
                              bfcacheNotUsed) {
  const inputDir = mkdtempSync(path.join(evidenceDir, "content-input-"));
  const canary = `LFWEB-CANARY-${randomBytes(12).toString("hex")}`;
  const moduleRuntimeSnapshots = [];
  const captureRuntime = async (label, establishInitial = false) => {
    try {
      const snapshot = await captureModuleRuntime(cdp, label, establishInitial);
      moduleRuntimeSnapshots.push(snapshot);
      return snapshot;
    } catch (error) {
      error.moduleRuntimeSnapshots = moduleRuntimeSnapshots;
      throw error;
    }
  };
  const canaryPayload = `${canary}-PRIVATE-CONTENT`;
  const markers = [
    canary,
    canaryPayload,
    Buffer.from(canaryPayload).toString("hex"),
    Buffer.from(canaryPayload).toString("base64"),
    sha256(Buffer.from(canaryPayload)),
  ];
  try {
    await captureRuntime("content-start", true);
    const fixtureValues = await evaluate(cdp, "window.LibFuturoHost.fixtureBytes()");
    if (!Array.isArray(fixtureValues) || fixtureValues.length !== 16512) {
      throw new Error("generated diagnostic fixture is unavailable for content probes");
    }
    const fixture = Buffer.from(fixtureValues);
    const emptyPath = path.join(inputDir, `${canary}-empty.a78`);
    const oversizedPath = path.join(inputDir, `${canary}-oversized.a78`);
    const malformedPath = path.join(inputDir, `${canary}-malformed.a78`);
    const truncatedPath = path.join(inputDir, `${canary}-truncated.a78`);
    const validPath = path.join(inputDir, `${canary}-valid-retry.a78`);
    writeFileSync(emptyPath, Buffer.alloc(0), { mode: 0o600 });
    const oversized = Buffer.alloc(1_048_705, 0x41);
    Buffer.from(canaryPayload).copy(oversized);
    writeFileSync(oversizedPath, oversized, { mode: 0o600 });
    const malformed = Buffer.alloc(256, 0x45);
    Buffer.from(canaryPayload).copy(malformed);
    writeFileSync(malformedPath, malformed, { mode: 0o600 });
    const truncated = Buffer.from(fixture.subarray(0, fixture.length - 1));
    Buffer.from(canaryPayload).copy(truncated, 128);
    writeFileSync(truncatedPath, truncated, { mode: 0o600 });
    markers.push(
      sha256(Buffer.alloc(0)),
      sha256(oversized),
      sha256(malformed),
      sha256(truncated),
    );
    writeFileSync(validPath, fixture, { mode: 0o600 });

    const empty = await selectContentFile(cdp, emptyPath, "empty", "zero-byte refusal");
    const emptyBefore = readCounters(empty.before);
    const emptyAfter = readCounters(empty.after);
    await captureRuntime("after-empty-refusal");
    const emptyReadDelta = counterDelta(emptyAfter, emptyBefore, "reads");
    const emptyWasmCopyDelta = counterDelta(emptyAfter, emptyBefore, "wasmCopies");
    const emptyCopyDelta = counterDelta(emptyAfter, emptyBefore, "copies");
    const emptyLoadDelta = counterDelta(emptyAfter, emptyBefore, "loads");
    const emptyProgressDelta = counterDelta(emptyAfter, emptyBefore, "progress");
    const emptyAdvanceDelta = counterDelta(emptyAfter, emptyBefore, "advances");

    const oversizedFile = await selectContentFile(
      cdp, oversizedPath, "oversized", "over-limit refusal",
    );
    await captureRuntime("after-oversized-refusal");
    const oversizedBefore = readCounters(oversizedFile.before);
    const oversizedAfter = readCounters(oversizedFile.after);
    const oversizedReadDelta = counterDelta(oversizedAfter, oversizedBefore, "reads");
    const oversizedWasmCopyDelta = counterDelta(oversizedAfter, oversizedBefore, "wasmCopies");
    const oversizedCopyDelta = counterDelta(oversizedAfter, oversizedBefore, "copies");
    const oversizedLoadDelta = counterDelta(oversizedAfter, oversizedBefore, "loads");
    const oversizedProgressDelta = counterDelta(oversizedAfter, oversizedBefore, "progress");
    const oversizedAdvanceDelta = counterDelta(oversizedAfter, oversizedBefore, "advances");

    const malformedFile = await selectContentFile(
      cdp, malformedPath, "load-refused", "malformed under-limit refusal",
    );
    await captureRuntime("after-malformed-refusal");
    const malformedBefore = readCounters(malformedFile.before);
    const malformedAfter = readCounters(malformedFile.after);
    const malformedCanvasBlank = await evaluate(cdp, "window.LibFuturoHost.canvasBlank()");
    const malformedGenericStatus = await evaluate(cdp,
      "document.querySelector('#status').textContent === 'This A78 file could not be loaded. Choose a non-empty .a78 file within the 1,048,704-byte limit that the selected profile supports, then try again.'");

    const truncatedFile = await selectContentFile(
      cdp, truncatedPath, "load-refused", "truncated under-limit refusal",
    );
    await captureRuntime("after-truncated-refusal");
    const truncatedBefore = readCounters(truncatedFile.before);
    const truncatedAfter = readCounters(truncatedFile.after);
    const truncatedCanvasBlank = await evaluate(cdp, "window.LibFuturoHost.canvasBlank()");
    const truncatedGenericStatus = await evaluate(cdp,
      "document.querySelector('#status').textContent === 'This A78 file could not be loaded. Choose a non-empty .a78 file within the 1,048,704-byte limit that the selected profile supports, then try again.'");

    const valid = await selectContentFile(cdp, validPath, "loaded", "valid fixture retry");
    await captureRuntime("after-valid-retry");
    const validBefore = readCounters(valid.before);
    const validAfter = readCounters(valid.after);
    const validLoaded = validAfter.reads === validBefore.reads + 1 &&
      validAfter.wasmCopies === validBefore.wasmCopies + 1 &&
      validAfter.copies === validBefore.copies + 1 &&
      validAfter.loads === validBefore.loads + 1 &&
      validAfter.progress === 0 && valid.after.last_load_accepted === true;
    if (!validLoaded) {
      const diagnostic = {
        before: validBefore,
        after: validAfter,
        selection: valid.after.last_selection,
        load_accepted: valid.after.last_load_accepted,
        load_status: valid.after.last_load_status,
      };
      throw new Error("valid fixture retry did not pass the public load boundary: " +
        JSON.stringify(diagnostic));
    }

    await installFrameCaptureAtProgress(cdp, "__libfuturoContentOracleFrame", 2);
    await clickTrusted(cdp, "#start-session");
    const observation = await waitForValue(
      cdp,
      "({host:window.LibFuturoHost.report(),frame:window.__libfuturoContentOracleFrame})",
      value => value.host.started && value.host.audio_graph_rms > 0 &&
        value.frame?.progress === 2,
      "content retry Start and second public frame",
    );
    const started = observation.host;
    const frame = observation.frame;
    if (!frame || frame.progress !== 2 || frame.frame_progress !== 2 ||
        frame.input_buttons !== 0) {
      throw new Error("valid retry did not capture the second steady frame with released input");
    }
    const expectedRaw = expectedSteadyRawFrame(0x33);
    const validFrame = sameArray(frame.raw, expectedRaw) &&
      sameArray(frame.canvas, expectedCanvasFrame(expectedRaw));

    const protocolResponse = await fetch(`http://127.0.0.1:${browserPort}/json/protocol`, {
      signal: AbortSignal.timeout(5_000),
    });
    if (!protocolResponse.ok) throw new Error("pinned browser CDP protocol description unavailable");
    const protocol = await protocolResponse.json();
    const browserDomain = protocol.domains?.find(domain => domain.domain === "Browser");
    const commands = new Set((browserDomain?.commands ?? []).map(command => command.name));
    if (!commands.has("getWindowForTarget") || !commands.has("setWindowBounds")) {
      throw new Error("pinned browser lacks the required minimize and restore CDP commands");
    }
    const windowInfo = await browserCdp.send("Browser.getWindowForTarget", { targetId });
    let minimizedReport;
    let restoredReport;
    try {
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "minimized" },
      });
      minimizedReport = await waitForValue(
        cdp,
        "window.LibFuturoHost.report()",
        value => value.document_hidden && value.paused &&
          value.visibility_events.includes("hidden"),
        "browser-window minimize visibility transition",
      );
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "normal" },
      });
      restoredReport = await waitForValue(
        cdp,
        "window.LibFuturoHost.report()",
        value => !value.document_hidden && value.visibility_events.includes("visible"),
        "browser-window restore visibility transition",
      );
    } finally {
      await browserCdp.send("Browser.setWindowBounds", {
        windowId: windowInfo.windowId,
        bounds: { windowState: "normal" },
      }).catch(() => {});
    }
    const minimizedHidden = minimizedReport.document_hidden === true &&
      minimizedReport.paused === true &&
      minimizedReport.visibility_events.includes("hidden");
    const restoredVisible = restoredReport.document_hidden === false &&
      restoredReport.visibility_events.includes("visible");

    const sameOriginBefore = await evaluate(cdp, "location.origin");
    await cdp.send("Page.navigate", { url: `${localOrigin}/next` });
    await waitForValue(
      cdp,
      "({href:location.href,documentComplete:document.readyState})",
      value => value?.href === `${localOrigin}/next` && value.documentComplete !== "loading",
      "same-origin navigation document load",
      20_000,
    );
    await captureRuntime("next-document-loaded", true);
    await waitForValue(
      cdp,
      "({complete:document.body?.dataset.complete,result:document.body?.dataset.result,ready:document.body?.dataset.ready})",
      value => value?.complete === "true" && value.result === "pass" && value.ready === "true",
      "same-origin BFCache probe destination",
      20_000,
    );
    const nextRuntime = await captureRuntime("next-runtime-ready");
    if (!Object.values(nextRuntime.public_api_types ?? {}).every(type => type === "function") ||
        nextRuntime.same_initial_module !== true || nextRuntime.same_initial_host !== true) {
      throw new Error("same-origin destination did not finish browser runtime initialization");
    }
    const history = await cdp.send("Page.getNavigationHistory");
    const previousEntry = history.entries?.[history.currentIndex - 1];
    if (!previousEntry || new URL(previousEntry.url).origin !== sameOriginBefore) {
      throw new Error("same-origin browser history entry unavailable for the BFCache probe");
    }
    await cdp.send("Page.navigateToHistoryEntry", { entryId: previousEntry.id });
    await waitForValue(
      cdp,
      "({href:location.href,documentComplete:document.readyState})",
      value => value?.href === `${localOrigin}/` && value.documentComplete !== "loading",
      "same-origin history return document load",
      20_000,
    );
    await captureRuntime("history-return-document-loaded", true);
    await waitForValue(
      cdp,
      "({complete:document.body?.dataset.complete,result:document.body?.dataset.result,ready:document.body?.dataset.ready})",
      value => value?.complete === "true" && value.result === "pass" && value.ready === "true",
      "same-origin BFCache return",
      20_000,
    );
    const restoredRuntime = await captureRuntime("history-return-runtime-ready");
    if (!Object.values(restoredRuntime.public_api_types ?? {}).every(type => type === "function") ||
        restoredRuntime.same_initial_module !== true || restoredRuntime.same_initial_host !== true) {
      throw new Error("returned document did not finish browser runtime initialization");
    }
    await delay(100);
    const restoredPage = await evaluate(cdp, "({origin:location.origin,host:window.LibFuturoHost.report()})");
    const bfcachePersisted = restoredPage.host.lifecycle.includes("pagehide-persisted") &&
      restoredPage.host.lifecycle.includes("pageshow-persisted");
    const bfcacheReasons = [...new Set(
      bfcacheNotUsed.flatMap(event => collectBfcacheReasons(event)),
    )].sort();
    const sameOriginBfcache = restoredPage.origin === sameOriginBefore &&
      sameOriginBefore === new URL(`${localOrigin}/`).origin;
    const storageState = await evaluate(cdp,
      "(async()=>({local:localStorage.length,session:sessionStorage.length,cookies:document.cookie.length,caches:typeof caches==='undefined'?-1:(await caches.keys()).length,databases:typeof indexedDB.databases==='function'?(await indexedDB.databases()).length:-1}))()");
    const storageClean = storageState.local === 0 && storageState.session === 0 &&
      storageState.cookies === 0 && storageState.caches === 0 && storageState.databases === 0;

    const contentResult = {
      result: "pass",
      profile_first: started.profile_first,
      initialize_profile_queries: valid.after.initialize_profile_queries,
      first_read_profile_queries_before: malformedFile.after.first_read_profile_queries_before,
      first_read_count_before: malformedFile.after.first_read_count_before,
      first_read_profile_gate_before: malformedFile.after.first_read_profile_gate_before,
      profile_queries_before_reads: valid.after.profile_queries_before_reads,
      profile_gate_before_reads: valid.after.profile_gate_before_reads,
      empty_read_delta: emptyReadDelta,
      empty_wasm_copy_delta: emptyWasmCopyDelta,
      empty_copy_delta: emptyCopyDelta,
      empty_load_delta: emptyLoadDelta,
      empty_progress_delta: emptyProgressDelta,
      empty_advance_delta: emptyAdvanceDelta,
      oversized_read_delta: oversizedReadDelta,
      oversized_wasm_copy_delta: oversizedWasmCopyDelta,
      oversized_copy_delta: oversizedCopyDelta,
      oversized_load_delta: oversizedLoadDelta,
      oversized_progress_delta: oversizedProgressDelta,
      oversized_advance_delta: oversizedAdvanceDelta,
      malformed_read_delta: counterDelta(malformedAfter, malformedBefore, "reads"),
      malformed_wasm_copy_delta: counterDelta(malformedAfter, malformedBefore, "wasmCopies"),
      malformed_copy_delta: counterDelta(malformedAfter, malformedBefore, "copies"),
      malformed_load_delta: counterDelta(malformedAfter, malformedBefore, "loads"),
      malformed_progress_delta: counterDelta(malformedAfter, malformedBefore, "progress"),
      malformed_advance_delta: counterDelta(malformedAfter, malformedBefore, "advances"),
      malformed_canvas_blank: malformedCanvasBlank,
      malformed_generic_status: malformedGenericStatus,
      truncated_read_delta: counterDelta(truncatedAfter, truncatedBefore, "reads"),
      truncated_wasm_copy_delta: counterDelta(truncatedAfter, truncatedBefore, "wasmCopies"),
      truncated_copy_delta: counterDelta(truncatedAfter, truncatedBefore, "copies"),
      truncated_load_delta: counterDelta(truncatedAfter, truncatedBefore, "loads"),
      truncated_progress_delta: counterDelta(truncatedAfter, truncatedBefore, "progress"),
      truncated_advance_delta: counterDelta(truncatedAfter, truncatedBefore, "advances"),
      truncated_canvas_blank: truncatedCanvasBlank,
      truncated_generic_status: truncatedGenericStatus,
      valid_retry: validLoaded && validFrame,
      valid_retry_load_delta: counterDelta(validAfter, validBefore, "loads"),
      valid_retry_frame_oracle: validFrame,
      valid_retry_frame_progress: frame.progress,
      valid_retry_input_buttons: frame.input_buttons,
      start_trusted: started.trusted_start,
      user_activation: started.user_activation,
      audio_rate: started.audio_rate,
      audio_graph_rms: started.audio_graph_rms,
      minimized_hidden: minimizedHidden,
      restored_visible: restoredVisible,
      same_origin_bfcache: sameOriginBfcache,
      bfcache_persisted: bfcachePersisted,
      bfcache_qualification: "not-qualified",
      bfcache_not_restored_reasons: bfcacheReasons,
      bfcache_lifecycle: restoredPage.host.lifecycle,
      module_runtime_snapshots: moduleRuntimeSnapshots,
      request_scan_complete: false,
      request_methods_get_only: false,
      storage_clean: storageClean,
    };
    pagePayload.results.content = contentResult;
    return {
      pagePayload,
      finalizePrivacy() {
        const requestScanComplete = browserRequestObservations.every(
          observation => observation.postDataComplete === true,
        );
        const requestMethodsGetOnly = browserRequestObservations.every(
          observation => observation.method === "GET",
        );
        const requestUrlsClean = browserRequestObservations.every(
          observation => observation.queryEmpty === true &&
            observation.fragmentEmpty === true && observation.routeAllowed === true,
        );
        contentResult.request_scan_complete = requestScanComplete;
        contentResult.request_methods_get_only = requestMethodsGetOnly;
        contentResult.request_urls_clean = requestUrlsClean;
        const material = JSON.stringify({
          pagePayload,
          requests: requestLog,
          requestObservations: browserRequestObservations,
          consoleObservations: browserConsoleObservations,
          networkErrors: browserNetworkErrors,
          consoleErrors: browserConsoleErrors,
          protocolErrors,
          storageState,
        });
        contentResult.privacy_clean = markers.every(marker => !material.includes(marker)) &&
          !material.includes(inputDir) && requestScanComplete && requestMethodsGetOnly &&
          requestUrlsClean &&
          !Object.keys(contentResult).some(key => /user_(file|content).*(hash|sha)/i.test(key));
      },
    };
  } catch (error) {
    error.moduleRuntimeSnapshots = moduleRuntimeSnapshots;
    throw error;
  } finally {
    rmSync(inputDir, { recursive: true, force: true });
  }
}

async function stopBrowser(browser, logStream) {
  if (browser && browser.exitCode === null && browser.signalCode === null) {
    browser.kill("SIGTERM");
    try {
      await Promise.race([once(browser, "exit"), delay(5_000)]);
    } catch {
      // Browser teardown is best effort after the bounded run has completed.
    }
    if (browser.exitCode === null && browser.signalCode === null) browser.kill("SIGKILL");
  }
  if (logStream) {
    logStream.end();
    await Promise.race([once(logStream, "finish"), delay(2_000)]);
  }
}

async function runBrowser() {
  requireEnvironment();
  const started = Date.now();
  const consumerDir = process.env.LIBFUTURO_CONSUMER_DIR;
  const consumerReportPath = process.env.LIBFUTURO_CONSUMER_REPORT;
  const reportPath = process.env.LIBFUTURO_BROWSER_REPORT;
  const archivePath = process.env.LIBFUTURO_BROWSER_ARCHIVE;
  const browserBinary = process.env.LIBFUTURO_BROWSER_BINARY;
  const runtimePackagesPath = process.env.LIBFUTURO_BROWSER_RUNTIME_PACKAGES;
  const scenario = process.env.LIBFUTURO_BROWSER_SCENARIO || "all";
  const consumerReport = JSON.parse(readFileSync(consumerReportPath, "utf8"));
  const packageInfo = consumerReport.package;
  const expectedConsumerHashes = {
    javascript: consumerReport.consumer.javascript_sha256,
    wasm: consumerReport.consumer.wasm_sha256,
  };

  if (consumerReport.status !== "consumer-build-pass" ||
      consumerReport.source_commit !== process.env.LIBFUTURO_SOURCE_REVISION ||
      packageInfo?.profile !== "muhtari-ntsc-v2" ||
      packageInfo?.configuration !== "muhtari-ntsc-battery-diagnostic" ||
      packageInfo?.api_revision !== 8 || packageInfo?.abi_revision !== 1 ||
      packageInfo?.behavior_revision !== 6 ||
      consumerReport.fixture_metadata?.loaded_or_read !== false) {
    throw new Error("consumer report did not identify the expected moved package and non-loaded fixture");
  }

  const archiveSha256 = await hashFile(archivePath);
  if (archiveSha256 !== process.env.LIBFUTURO_BROWSER_ARCHIVE_SHA256) {
    throw new Error("downloaded official browser archive did not match its pinned SHA-256");
  }
  const artifactPaths = {
    html: path.join(consumerDir, "consumer.html"),
    host: path.join(consumerDir, "consumer-host.js"),
    javascript: path.join(consumerDir, "consumer.js"),
    wasm: path.join(consumerDir, "consumer.wasm"),
  };
  const hostControllerSha256 = await hashFile(artifactPaths.host);
  if (!existsSync(path.join(consumerDir, "MUHTARI-PALETTE-NOTICES.md"))) {
    throw new Error("relocated consumer palette license notice is missing");
  }
  const actualConsumerHashes = {
    javascript: await hashFile(artifactPaths.javascript),
    wasm: await hashFile(artifactPaths.wasm),
  };
  const wasmModuleExports = WebAssembly.Module.exports(
    new WebAssembly.Module(readFileSync(artifactPaths.wasm)),
  ).map(({ name, kind }) => ({ name, kind }));
  if (actualConsumerHashes.javascript !== expectedConsumerHashes.javascript ||
      actualConsumerHashes.wasm !== expectedConsumerHashes.wasm) {
    throw new Error("served consumer artifacts differ from the relocated build report");
  }

  const versionResult = await execFileAsync(browserBinary, ["--version"], {
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
  });
  const browserVersionOutput = versionResult.stdout.trim();
  if (!browserVersionOutput.includes(process.env.LIBFUTURO_BROWSER_VERSION)) {
    throw new Error("extracted browser binary version did not match the pinned official release");
  }
  const runtimePackages = readFileSync(runtimePackagesPath, "utf8").trim().split("\n").filter(Boolean);
  const osRelease = readFileSync("/etc/os-release", "utf8");
  const osPrettyName = osRelease.match(/^PRETTY_NAME="?([^"\n]+)"?/m)?.[1] ?? "unknown Linux distribution";

  const expectedResponses = new Map([
    ["/", { mime: "text/html", sha256: null }],
    ["/next", { mime: "text/html", sha256: null }],
    ["/consumer-host.js", { mime: "text/javascript", sha256: hostControllerSha256 }],
    ["/consumer.js", { mime: "text/javascript", sha256: expectedConsumerHashes.javascript }],
    ["/consumer.wasm", { mime: "application/wasm", sha256: expectedConsumerHashes.wasm }],
  ]);
  const requestLog = [];
  const pagehideReports = [];
  const browserRequestObservations = [];
  const browserConsoleObservations = [];
  const browserNetworkErrors = [];
  const browserConsoleErrors = [];
  const protocolErrors = [];
  const bfcacheNotUsed = [];
  const responseMeta = new Map();
  const observedResponseHashes = new Map();
  const pendingBodyReads = new Set();
  let localOrigin = "";
  const servedFiles = new Map([
    ["/", { file: artifactPaths.html, mime: "text/html; charset=utf-8" }],
    ["/next", { file: artifactPaths.html, mime: "text/html; charset=utf-8" }],
    ["/consumer-host.js", { file: artifactPaths.host, mime: "text/javascript; charset=utf-8" }],
    ["/consumer.js", { file: artifactPaths.javascript, mime: "text/javascript; charset=utf-8" }],
    ["/consumer.wasm", { file: artifactPaths.wasm, mime: "application/wasm" }],
  ]);
  const server = createServer((request, response) => {
    const pathname = new URL(request.url ?? "/", localOrigin).pathname;
    const parsedRequestUrl = new URL(request.url ?? "/", localOrigin);
    const lifecycleEvidencePost = scenario === "host-lifecycle" &&
      request.url === "/lifecycle-pagehide" && request.method === "POST";
    browserRequestObservations.push({
      url: request.url ?? "/",
      method: request.method ?? "GET",
      hasPostData: lifecycleEvidencePost,
      postData: null,
      postDataComplete: true,
      queryEmpty: parsedRequestUrl.search === "",
      fragmentEmpty: parsedRequestUrl.hash === "",
      routeAllowed: parsedRequestUrl.pathname === "/favicon.ico" ||
        expectedResponses.has(parsedRequestUrl.pathname) || lifecycleEvidencePost,
    });
    const safePath = pathname === "/favicon.ico" || expectedResponses.has(pathname)
      || lifecycleEvidencePost ? pathname
      : "unmatched";
    if (lifecycleEvidencePost) {
      const chunks = [];
      let bytesRead = 0;
      let tooLarge = false;
      request.on("data", chunk => {
        bytesRead += chunk.length;
        if (bytesRead <= 4096) chunks.push(chunk);
        else tooLarge = true;
      });
      request.on("end", () => {
        let report;
        try {
          report = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        } catch {
          report = null;
        }
        const expectedKeys = ["audio_queue_frames", "audio_queue_samples", "audio_sources_stopped",
          "input_buttons", "lifecycle_pagehide", "paused", "token"].sort();
        const keys = report && typeof report === "object" && !Array.isArray(report)
          ? Object.keys(report).sort()
          : [];
        const valid = !tooLarge && bytesRead <= 4096 && report &&
          JSON.stringify(keys) === JSON.stringify(expectedKeys) &&
          typeof report.token === "string" && /^[a-f0-9]{16}$/.test(report.token) &&
          typeof report.paused === "boolean" && report.input_buttons === 0 &&
          Number.isInteger(report.audio_queue_frames) && report.audio_queue_frames === 0 &&
          Number.isInteger(report.audio_queue_samples) && report.audio_queue_samples === 0 &&
          Number.isInteger(report.audio_sources_stopped) &&
          typeof report.lifecycle_pagehide === "boolean";
        if (valid) pagehideReports.push(report);
        requestLog.push({ path: safePath, status: valid ? 204 : 400, method: "POST", body_bytes: bytesRead });
        response.writeHead(valid ? 204 : 400, { "cache-control": "no-store" });
        response.end();
      });
      return;
    }
    if (pathname === "/favicon.ico") {
      response.writeHead(204, { "cache-control": "no-store" });
      response.end();
      requestLog.push({ path: safePath, status: 204 });
      return;
    }
    const served = servedFiles.get(pathname);
    if (request.method !== "GET" || !served) {
      requestLog.push({ path: safePath, status: 404 });
      response.writeHead(404, { "cache-control": "no-store" });
      response.end();
      return;
    }
    const bytes = readFileSync(served.file);
    response.writeHead(200, {
      "content-type": served.mime,
      "content-length": String(bytes.length),
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'unsafe-inline'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'",
      "x-content-type-options": "nosniff",
    });
    response.end(bytes);
    requestLog.push({ path: safePath, status: 200, mime: served.mime.split(";")[0], sha256: sha256(bytes) });
  });

  let cdp = null;
  let browserCdp = null;
  let browser = null;
  let browserLog = null;
  let profileDir = "";
  const result = {
    schema_version: 2,
    status: "browser-failed",
    source_tree: consumerReport.source_tree,
    outer_runner: consumerReport.outer_runner,
    docker_daemon: consumerReport.docker_daemon,
    container: consumerReport.container,
    identity_assurance: "lineage-and-mismatch-detection; not authentication or attestation",
    browser: {
      product: "Chrome for Testing Headless Shell",
      version_expected: process.env.LIBFUTURO_BROWSER_VERSION,
      archive_sha256: archiveSha256,
      archive_sha256_expected: process.env.LIBFUTURO_BROWSER_ARCHIVE_SHA256,
      binary_version: browserVersionOutput,
      operating_system: osPrettyName,
      requested_platform: process.env.LIBFUTURO_SDK_PLATFORM,
      container_architecture: consumerReport.sdk.container_architecture,
      node_architecture: process.arch,
      runtime_packages_classification: consumerReport.browser.runtime_packages_classification,
      runtime_packages: runtimePackages,
      release_channel: "Stable",
      release_revision: process.env.LIBFUTURO_CFT_REVISION,
      artifact_url: process.env.LIBFUTURO_CFT_URL,
      metadata_url: "https://googlechromelabs.github.io/chrome-for-testing/",
      launch_flags: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
    },
    sdk: { image: process.env.LIBFUTURO_SDK_IMAGE, requested_platform: process.env.LIBFUTURO_SDK_PLATFORM, resolved_platform: consumerReport.sdk.resolved_platform, container_architecture: consumerReport.sdk.container_architecture, compiler: consumerReport.sdk.compiler },
    input: {
      source_snapshot_kind: consumerReport.source_snapshot_kind,
      source_commit: consumerReport.source_commit,
      source_tree: consumerReport.source_tree,
      target: packageInfo.target,
      core: packageInfo.core,
      core_version: packageInfo.core_version,
      core_source_revision: packageInfo.core_source_revision,
      package_build_id: packageInfo.libfuturo_build_id,
      package_archive_sha256: packageInfo.archive_sha256,
      core_archive_sha256: packageInfo.core_archive_sha256,
      profile: packageInfo.profile,
      configuration: packageInfo.configuration,
      api_revision: packageInfo.api_revision,
      abi_revision: packageInfo.abi_revision,
      behavior_revision: packageInfo.behavior_revision,
      fixture_metadata: consumerReport.fixture_metadata,
      javascript_sha256: actualConsumerHashes.javascript,
      host_controller_sha256: hostControllerSha256,
      wasm_sha256: actualConsumerHashes.wasm,
      link_command: consumerReport.consumer.link_command,
    },
    wasm_module_exports: wasmModuleExports,
    served_artifact_hashes: {},
    scenarios: null,
    requests: requestLog,
    console_errors: browserConsoleErrors,
    network_errors: browserNetworkErrors,
    protocol_errors: protocolErrors,
    elapsed_seconds: null,
  };

  try {
    const listening = new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    await listening;
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("loopback server did not provide a TCP port");
    localOrigin = `http://127.0.0.1:${address.port}`;
    profileDir = mkdtempSync("/work/browser-profile-");
    browserLog = createWriteStream(
      process.env.LIBFUTURO_BROWSER_PROCESS_LOG ?? "/work/evidence/browser-process.log",
      { flags: "wx", mode: 0o600 },
    );
    const launchArgs = [
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-default-apps",
      "--disable-extensions",
      "--disable-sync",
      "--metrics-recording-only",
      "--no-first-run",
      "--no-default-browser-check",
      "--remote-debugging-address=127.0.0.1",
      "--remote-debugging-port=0",
      "--remote-allow-origins=*",
      `--user-data-dir=${profileDir}`,
      "about:blank",
    ];
    browser = spawn(browserBinary, launchArgs, { stdio: ["ignore", "ignore", "pipe"] });
    browser.stderr.pipe(browserLog);
    const activePortFile = path.join(profileDir, "DevToolsActivePort");
    let browserPort = 0;
    const startupDeadline = Date.now() + 20_000;
    while (Date.now() < startupDeadline) {
      if (browser.exitCode !== null || browser.signalCode !== null) {
        throw new Error("pinned browser exited before its CDP endpoint became ready");
      }
      if (existsSync(activePortFile)) {
        const parsedPort = Number(readFileSync(activePortFile, "utf8").split("\n", 1)[0]);
        if (Number.isInteger(parsedPort) && parsedPort > 0 && parsedPort < 65536) {
          browserPort = parsedPort;
          break;
        }
      }
      await delay(100);
    }
    if (!browserPort) throw new Error("pinned browser did not expose its CDP endpoint within 20 seconds");
    const targetsResponse = await fetch(`http://127.0.0.1:${browserPort}/json/list`, { signal: AbortSignal.timeout(5_000) });
    if (!targetsResponse.ok) throw new Error("local browser CDP target list was unavailable");
    const targets = await targetsResponse.json();
    const pageTarget = targets.find(target => target.type === "page" && target.webSocketDebuggerUrl);
    if (!pageTarget) throw new Error("pinned browser did not create a page target");
    cdp = await CdpConnection.connect(pageTarget.webSocketDebuggerUrl);
    const versionResponse = await fetch(`http://127.0.0.1:${browserPort}/json/version`, {
      signal: AbortSignal.timeout(5_000),
    });
    if (!versionResponse.ok) throw new Error("local browser CDP browser endpoint unavailable");
    const browserVersion = await versionResponse.json();
    if (typeof browserVersion.webSocketDebuggerUrl !== "string") {
      throw new Error("pinned browser did not expose its browser-level CDP endpoint");
    }
    browserCdp = await CdpConnection.connect(browserVersion.webSocketDebuggerUrl);
    cdp.onEvent(message => {
      if (message.method === "Harness.protocolError") {
        protocolErrors.push({ kind: "invalid-cdp-message" });
      } else if (message.method === "Runtime.exceptionThrown") {
        browserConsoleObservations.push(JSON.stringify(message.params?.exceptionDetails ?? {}));
        browserConsoleErrors.push({ kind: "exception" });
      } else if (message.method === "Runtime.consoleAPICalled") {
        browserConsoleObservations.push(JSON.stringify(message.params ?? {}));
        if (message.params?.type === "error") browserConsoleErrors.push({ kind: "console" });
      } else if (message.method === "Log.entryAdded") {
        browserConsoleObservations.push(JSON.stringify(message.params?.entry ?? {}));
        if (message.params?.entry?.level === "error") browserConsoleErrors.push({ kind: "log" });
      } else if (message.method === "Page.backForwardCacheNotUsed") {
        bfcacheNotUsed.push(message.params ?? {});
      } else if (message.method === "Network.requestWillBeSent") {
        const requestId = message.params.requestId;
        const parsed = new URL(message.params.request.url);
        const request = message.params.request;
        const requestUrl = new URL(request.url);
        const postData = typeof request.postData === "string" ? request.postData : null;
        const postDataBytes = postData === null ? 0 : Buffer.byteLength(postData);
        const postDataComplete = request.hasPostData !== true || postData !== null;
        const postDataWithinBound = postDataBytes <= 1_048_704;
        const lifecycleEvidencePost = scenario === "host-lifecycle" &&
          requestUrl.pathname === "/lifecycle-pagehide" && request.method === "POST" &&
          requestUrl.search === "" && requestUrl.hash === "";
        browserRequestObservations.push({
          url: request.url,
          method: request.method,
          hasPostData: lifecycleEvidencePost || request.hasPostData === true || postData !== null,
          postData: lifecycleEvidencePost || postData === null ? null : postData.slice(0, 1_048_704),
          postDataComplete: lifecycleEvidencePost || postDataComplete && postDataWithinBound,
          queryEmpty: requestUrl.search === "",
          fragmentEmpty: requestUrl.hash === "",
          routeAllowed: requestUrl.pathname === "/favicon.ico" ||
            expectedResponses.has(requestUrl.pathname) || lifecycleEvidencePost,
        });
        if (!lifecycleEvidencePost &&
            (request.method !== "GET" || request.hasPostData === true || postData !== null)) {
          browserNetworkErrors.push({ kind: "unexpected-request-body" });
        }
        if (parsed.origin !== localOrigin) {
          browserNetworkErrors.push({ kind: "non-loopback-request" });
        }
        if (requestUrl.search !== "" || requestUrl.hash !== "" ||
            (requestUrl.pathname !== "/favicon.ico" && !expectedResponses.has(requestUrl.pathname))) {
          browserNetworkErrors.push({ kind: "unexpected-request-url" });
        }
        const safePath = parsed.pathname === "/favicon.ico" || expectedResponses.has(parsed.pathname) ||
          lifecycleEvidencePost
          ? parsed.pathname
          : "unmatched";
        responseMeta.set(requestId, { path: safePath, lifecycleEvidencePost });
      } else if (message.method === "Network.responseReceived") {
        const requestId = message.params.requestId;
        const parsed = new URL(message.params.response.url);
        const expected = expectedResponses.get(parsed.pathname);
        const meta = responseMeta.get(requestId) ?? { path: parsed.pathname };
        meta.status = message.params.response.status;
        meta.mime = message.params.response.mimeType;
        responseMeta.set(requestId, meta);
        const isEmptyFavicon = parsed.pathname === "/favicon.ico" && meta.status === 204;
        const isValidLifecycleEvidence = meta.lifecycleEvidencePost && meta.status === 204;
        if (parsed.origin !== localOrigin ||
            (!isEmptyFavicon && !isValidLifecycleEvidence &&
             (!expected || meta.status !== 200 || meta.mime !== expected.mime))) {
          browserNetworkErrors.push({ kind: "invalid-response", status: meta.status, mime: meta.mime });
        }
      } else if (message.method === "Network.loadingFinished") {
        const requestId = message.params.requestId;
        const meta = responseMeta.get(requestId);
        const expectedHash = meta && expectedResponses.get(meta.path)?.sha256;
        if (meta && (meta.path === "/consumer-host.js" || meta.path === "/consumer.js" || meta.path === "/consumer.wasm") &&
            observedResponseHashes.get(meta.path) !== expectedHash) {
          const read = cdp.send("Network.getResponseBody", { requestId }).then(body => {
            const bytes = body.base64Encoded ? Buffer.from(body.body, "base64") : Buffer.from(body.body, "utf8");
            observedResponseHashes.set(meta.path, sha256(bytes));
          }).catch(() => {
            browserNetworkErrors.push({ kind: "response-body-unavailable", path: meta.path });
          });
          pendingBodyReads.add(read);
          void read.finally(() => pendingBodyReads.delete(read));
        }
      } else if (message.method === "Network.loadingFailed") {
        const meta = responseMeta.get(message.params.requestId);
        if (!meta || meta.path !== "/favicon.ico") {
          browserNetworkErrors.push({ kind: "request-failed" });
        }
      }
    });

    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.send("Network.enable", { maxTotalBufferSize: 20_000_000, maxResourceBufferSize: 10_000_000 });
    await cdp.send("Log.enable");
    await cdp.send("Page.navigate", { url: `${localOrigin}/` });
    const pageDeadline = Date.now() + 45_000;
    let pageState = null;
    while (Date.now() < pageDeadline) {
      const evaluation = await cdp.send("Runtime.evaluate", {
        expression: "({complete: document.body?.dataset.complete, result: document.body?.dataset.result, output: document.querySelector('#result')?.textContent})",
        returnByValue: true,
        awaitPromise: true,
      });
      pageState = evaluation.result?.value ?? null;
      if (pageState?.complete === "true") break;
      if (pageState?.result === "fail") throw new Error("browser page marked an identity scenario as failed");
      await delay(100);
    }
    if (pageState?.complete !== "true" || pageState?.result !== "pass") {
      throw new Error("browser did not produce both required identity results within 45 seconds");
    }
    let pagePayload = JSON.parse(pageState.output);
    let finalizePrivacy = null;
    result.page_result_keys = Object.keys(pagePayload.results).sort();
    result.browser_runtime_exports = await captureModuleRuntime(cdp, "identity-ready", true);
    if (!Object.values(result.browser_runtime_exports.public_api_types ?? {}).every(
      type => type === "function",
    )) {
      throw new Error("browser runtime did not expose all public consumer APIs after startup");
    }
    await Promise.all([...pendingBodyReads]);
    if (scenario === "host-tracer") {
      pagePayload = await runHostTracer(cdp, packageInfo, pagePayload, path.dirname(reportPath));
    } else if (scenario === "host-content") {
      const hostContent = await runHostContent(
        cdp, browserCdp, browserPort, pageTarget.id, localOrigin, packageInfo,
        pagePayload, path.dirname(reportPath), requestLog, browserRequestObservations,
        browserConsoleObservations, browserNetworkErrors, browserConsoleErrors,
        protocolErrors, bfcacheNotUsed,
      );
      pagePayload = hostContent.pagePayload;
      finalizePrivacy = hostContent.finalizePrivacy;
    } else if (scenario === "host-input") {
      pagePayload = await runHostInput(
        cdp, browserCdp, browserPort, pageTarget.id, packageInfo,
        pagePayload, path.dirname(reportPath),
      );
    } else if (scenario === "host-input-audio") {
      pagePayload = await runHostInputAudio(
        cdp, packageInfo, pagePayload, path.dirname(reportPath),
      );
    } else if (scenario === "host-lifecycle") {
      pagePayload = await runHostLifecycle(
        cdp, browserCdp, browserPort, pageTarget.id, localOrigin, packageInfo,
        pagePayload, path.dirname(reportPath), bfcacheNotUsed, pagehideReports,
      );
    } else if (scenario === "host-ui") {
      pagePayload = await runHostUi(
        cdp, browserCdp, pageTarget.id, packageInfo, pagePayload,
        path.dirname(reportPath),
      );
    }
    await delay(200);
    await Promise.all([...pendingBodyReads]);
    await delay(100);
    await Promise.all([...pendingBodyReads]);
    for (const [route, expected] of expectedResponses) {
      if (route === "/favicon.ico") continue;
      if (route === "/next" && scenario !== "host-content" && scenario !== "host-lifecycle") continue;
      const response = requestLog.find(entry => entry.path === route && entry.status === 200);
      if (!response) throw new Error(`browser did not fetch required loopback route ${route}`);
      if (expected.sha256 && response.sha256 !== expected.sha256) {
        throw new Error(`loopback server served bytes with an unexpected digest for ${route}`);
      }
    }
    for (const route of ["/consumer-host.js", "/consumer.js", "/consumer.wasm"]) {
      const expected = expectedResponses.get(route).sha256;
      if (observedResponseHashes.get(route) !== expected) {
        throw new Error(`browser response bytes did not match the relocated artifact digest for ${route}`);
      }
    }
    if (browserNetworkErrors.length || browserConsoleErrors.length || protocolErrors.length) {
      throw new Error("browser reported a console, network, or CDP protocol failure");
    }
    if (finalizePrivacy) finalizePrivacy();
    result.served_artifact_hashes = Object.fromEntries(observedResponseHashes);
    result.page_results = pagePayload.results;
    result.scenarios = expectedScenarioResults(packageInfo, pagePayload, scenario);
    result.status = "browser-pass";
    result.elapsed_seconds = Math.round((Date.now() - started) / 100) / 10;
    return result;
  } catch (error) {
    await Promise.all([...pendingBodyReads]);
    result.served_artifact_hashes = Object.fromEntries(observedResponseHashes);
    result.failure = {
      kind: error?.name ?? "Error",
      message: cleanMessage(error?.message ?? error),
      runtime_diagnostics: error?.runtimeDiagnostics || error?.moduleRuntimeSnapshots
        ? {
            at_exception: error?.runtimeDiagnostics ?? null,
            content_module_snapshots: error?.moduleRuntimeSnapshots ?? null,
          }
        : null,
    };
    result.elapsed_seconds = Math.round((Date.now() - started) / 100) / 10;
    throw Object.assign(error instanceof Error ? error : new Error(String(error)), { browserReport: result });
  } finally {
    if (cdp) cdp.close();
    if (browserCdp) browserCdp.close();
    await stopBrowser(browser, browserLog);
    if (profileDir && existsSync(profileDir)) rmSync(profileDir, { recursive: true, force: true });
    if (server.listening) {
      server.closeAllConnections();
      server.close();
      await Promise.race([once(server, "close"), delay(2_000)]);
    }
  }
}

async function main() {
  let result;
  try {
    result = await runBrowser();
  } catch (error) {
    result = error?.browserReport ?? {
      schema_version: 2,
      status: "browser-failed",
      failure: { kind: error?.name ?? "Error", message: cleanMessage(error?.message ?? error) },
      browser: {
        product: "Chrome for Testing Headless Shell",
        version_expected: process.env.LIBFUTURO_BROWSER_VERSION ?? null,
        archive_sha256_expected: process.env.LIBFUTURO_BROWSER_ARCHIVE_SHA256 ?? null,
        requested_platform: process.env.LIBFUTURO_SDK_PLATFORM ?? null,
      },
    };
    result.status = "browser-failed";
    process.exitCode = 1;
  }
  const reportPath = process.env.LIBFUTURO_BROWSER_REPORT;
  if (reportPath) writeFileSync(reportPath, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
  const consumerReportPath = process.env.LIBFUTURO_CONSUMER_REPORT;
  if (consumerReportPath && existsSync(consumerReportPath)) {
    try {
      const consumerReport = JSON.parse(readFileSync(consumerReportPath, "utf8"));
      consumerReport.browser = {
        ...(consumerReport.browser ?? {}),
        status: result.status,
        product: result.browser?.product ?? "Chrome for Testing Headless Shell",
        version: result.browser?.binary_version ?? null,
        archive_sha256: result.browser?.archive_sha256 ?? null,
        requested_platform: result.browser?.requested_platform ?? process.env.LIBFUTURO_SDK_PLATFORM ?? null,
        scenarios: result.scenarios ?? null,
        elapsed_seconds: result.elapsed_seconds ?? null,
      };
      writeFileSync(consumerReportPath, `${JSON.stringify(consumerReport, null, 2)}\n`, { mode: 0o600 });
    } catch {
      process.exitCode = 1;
    }
  }
  if (result.status === "browser-pass") {
    process.stdout.write(`Pinned browser: ${result.browser.binary_version}; positive and mismatch identity scenarios passed; JS/Wasm digests verified.\n`);
  } else {
    process.stderr.write(`Pinned browser route failed: ${result.failure?.message ?? "unknown failure"}\n`);
  }
}

await main();
