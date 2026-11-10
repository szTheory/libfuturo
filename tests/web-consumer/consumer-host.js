/* SPDX-License-Identifier: MIT AND BSD-3-Clause
 * Warm NTSC palette copied from muhtari/host/palette.c at
 * d5fd241e3f4d701d73867cc2e465c56a6fe6793d.
 * The upstream table is derived from a7800 src/mame/drivers/a7800.cpp at
 * 7a2afdc1ea08fc331b16b750d8c1f02d4ef62fc8. Keep
 * MUHTARI-PALETTE-NOTICES.md with relocated host artifacts.
 */
(() => {
  "use strict";

  const WIDTH = 320;
  const HEIGHT = 242;
  const PIXELS = WIDTH * HEIGHT;
  const MAX_CONTENT_BYTES = 1048704;
  const PROFILE_ID = "muhtari-ntsc-v2";
  const CONFIGURATION_ID = "muhtari-ntsc-battery-diagnostic";
  const FRAME_NUMERATOR = 656711n;
  const FRAME_DENOMINATOR = 39375000n;
  const FRAME_STEP_SCALED_MICROSECONDS = FRAME_NUMERATOR * 1000000n;
  const KEY_BUTTONS = new Map([
    ["ArrowUp", 0x10], ["ArrowDown", 0x20], ["ArrowLeft", 0x40],
    ["ArrowRight", 0x80], [" ", 0x01],
  ]);
  const ORACLE_AUDIO_SAMPLE_COUNTS = [54, 801, 801, 800, 801, 800, 801, 800,
    801, 800, 801, 801, 800, 801, 800];
  const palette = new Uint32Array([0,1973790,3355443,4539717,5723991,6776679,7763574,8750469,9671571,10592673,11513775,12369084,13224393,14079702,14935011,15724527,2561280,3812096,4996608,6115328,7168256,8155136,9142016,10063360,10984471,11840045,12760896,13616210,14405986,15261298,16050817,16775055,4521984,5640192,6694912,7748352,8736000,9657856,10579456,11500817,12356648,13212220,14067790,14923103,15712878,16502654,16768140,16771226,5570560,6619136,7671552,8660736,9583360,10505238,11427116,12283199,13139025,13994849,14850417,15640448,16430479,16761501,16764842,16767928,5701632,6750208,7798808,8722222,9710913,10633298,11489635,12411507,13267586,14123408,14913438,15703468,16559033,16758982,16762579,16765664,4849717,5963847,7012441,7999849,8988792,9911431,10833557,11755171,12611249,13467070,14322891,15112920,15902948,16758513,16761853,16765183,3080295,4325495,5439622,6560148,7548834,8536752,9524157,10446026,11367383,12223203,13079024,13934588,14724351,15579903,16369663,16766207,131,1900690,3282080,4533165,5652155,6705352,7758037,8745185,9666542,10587898,11508991,12364543,13219839,14075135,14864895,15720191,136,5783,404901,2179250,3494335,4743884,5861849,6914534,7901170,8887806,9808895,10729727,11650559,12505855,13361151,14216191,6775,12422,17300,21666,1533104,2979005,4228042,5345751,6463459,7515632,8502012,9422847,10343679,11264511,12119551,13040127,12111,16992,21616,25727,29837,1933980,3314089,4562871,5680580,6732497,7784414,8770794,9691638,10612223,11532799,12386303,15117,19749,23865,27979,359516,2132844,3512699,4695946,5813656,6865574,7917492,8838081,9824462,10745051,11599847,12517363,15360,19968,24064,224770,2063646,3443763,4627014,5810263,6862439,7848823,8835205,9755796,10676642,11597231,12451773,13303754,13056,17920,1464064,2909952,4159232,5342464,6394893,7447078,8433466,9420108,10340956,11196012,12116859,12971914,13827224,14614438,1188096,2700544,4016128,5200128,6252800,7305216,8292096,9278720,10199835,11120944,11976259,12831573,13686885,14541940,15331715,16186770,3735552,4922880,6042368,7030016,8082944,9004800,9991680,10913024,11768604,12624178,13479748,14335061,15190374,15980149,16769924,16773011]);

  const fileInput = document.querySelector("#content-file");
  const startButton = document.querySelector("#start-session");
  const pauseButton = document.querySelector("#pause-session");
  const stopButton = document.querySelector("#stop-session");
  const stopWarning = document.querySelector("#stop-warning");
  const emptyState = document.querySelector("#empty-state");
  const statusNode = document.querySelector("#status");
  const canvas = document.querySelector("#playfield");
  const context = canvas.getContext("2d", { alpha: false, colorSpace: "srgb" });
  if (!fileInput || !startButton || !pauseButton || !stopButton || !stopWarning ||
      !emptyState || !statusNode || !canvas || !context) {
    throw new Error("required browser host element unavailable");
  }

  const state = {
    ready: false,
    profileValidated: false,
    reads: 0,
    wasmCopies: 0,
    initializeProfileQueries: 0,
    firstReadProfileQueriesBefore: null,
    firstReadCountBefore: null,
    firstReadProfileGateBefore: false,
    profileQueriesBeforeReads: [],
    profileGateBeforeReads: [],
    profileQueriesAfterSelectionGate: [],
    selections: 0,
    lastSelection: "none",
    loadStatus: -1,
    started: false,
    paused: false,
    stopped: false,
    activeAudio: false,
    inputButtons: 0,
    inputSamples: [],
    frameGate: null,
    frameHandle: null,
    pendingFrameCallback: null,
    capturedStaleFrameCallback: null,
    staleCallbackCaptured: false,
    staleCallbackInvoked: false,
    generation: 0,
    frameAdvancing: false,
    trustedStart: false,
    userActivation: false,
    startAttempts: 0,
    audioContext: null,
    audioResumePending: false,
    audioContextsCreated: 0,
    audioAnalyser: null,
    audioQueue: [],
    audioFramesProduced: 0,
    audioOracleFramesVerified: 0,
    audioOracleLastValid: false,
    audioBufferHistory: [],
    audioQueuePeakFrames: 0,
    audioQueuePeakSamples: 0,
    audioSourcesStopped: 0,
    nextAudioStartFailure: false,
    nextAudioTime: 0,
    audioRate: 0,
    audioRms: 0,
    visibilityEvents: [],
    lifecycle: [],
    lastLoadAccepted: false,
    fileReadPending: false,
    runtimeError: false,
    nextFileReadGate: null,
    activeFileReadRelease: null,
    nextRuntimeError: false,
    nextAudioResumeFailure: false
  };
  const heldKeys = new Set();

  const image = context.createImageData(WIDTH, HEIGHT, { colorSpace: "srgb" });
  const pixels = image.data;

  function setStatus(value) {
    statusNode.textContent = value;
  }

  const FILE_ERROR = "This A78 file could not be loaded. Choose a non-empty .a78 file within the 1,048,704-byte limit that the selected profile supports, then try again.";
  const START_ERROR = "This session could not start. Select Start session to try again.";
  const RESUME_ERROR = "This session could not resume. Select Resume session to try again.";
  const RUNTIME_ERROR = "This session could not continue. Select Stop session to end it, then choose the A78 file again to start a new session. Stopping discards in-memory battery changes.";

  function updateControls() {
    const active = state.started && !state.stopped;
    const hasContent = state.lastLoadAccepted && !state.stopped;
    const checking = state.fileReadPending;
    fileInput.disabled = checking || active || state.runtimeError;
    startButton.disabled = checking || !hasContent || state.runtimeError ||
      (active && !state.paused);
    startButton.textContent = active && state.paused ? "Resume session" : "Start session";
    pauseButton.disabled = checking || !active || state.paused || state.runtimeError;
    stopButton.disabled = checking || !hasContent;
    stopWarning.hidden = stopButton.disabled;
    emptyState.hidden = hasContent || state.stopped;
  }

  function resetSessionMetrics() {
    state.inputSamples = [];
    state.audioFramesProduced = 0;
    state.audioOracleFramesVerified = 0;
    state.audioOracleLastValid = false;
    state.audioBufferHistory = [];
    state.audioQueuePeakFrames = 0;
    state.audioQueuePeakSamples = 0;
    state.audioSourcesStopped = 0;
    state.audioRate = 0;
    state.audioRms = 0;
  }

  function clearCanvas() {
    context.clearRect(0, 0, WIDTH, HEIGHT);
  }

  function profileMatches() {
    state.profileValidated = Module._lfweb_profile_matches() === 1;
    return state.profileValidated &&
      Module._lfweb_max_content_bytes() === MAX_CONTENT_BYTES;
  }

  function copyAndRenderFrame() {
    const videoPointer = Module._lfweb_video_buffer();
    const raw = Module.HEAPU8.subarray(videoPointer, videoPointer + PIXELS);
    if (raw.length !== PIXELS) throw new Error("invalid public video extent");
    for (let index = 0; index < PIXELS; index += 1) {
      const rgb = palette[raw[index]];
      const at = index * 4;
      pixels[at] = (rgb >>> 16) & 255;
      pixels[at + 1] = (rgb >>> 8) & 255;
      pixels[at + 2] = rgb & 255;
      pixels[at + 3] = 255;
    }
    context.putImageData(image, 0, 0);
  }

  function resetRejectedSelection(message) {
    state.lastLoadAccepted = false;
    state.loadStatus = Module._lfweb_last_load_status();
    state.started = false;
    state.paused = false;
    state.stopped = false;
    state.runtimeError = false;
    clearCanvas();
    setStatus(message);
    updateControls();
  }

  async function onFileChange() {
    state.selections += 1;
    const selected = fileInput.files && fileInput.files.length === 1
      ? fileInput.files[0]
      : null;
    state.lastSelection = "pending";
    state.profileValidated = false;
    state.fileReadPending = true;
    setStatus("Checking file…");
    updateControls();

    const finishRead = () => {
      state.fileReadPending = false;
      updateControls();
    };

    // The profile gate intentionally precedes even reading File.size.
    if (!profileMatches()) {
      state.lastSelection = "profile-refused";
      resetRejectedSelection(FILE_ERROR);
      finishRead();
      return;
    }
    const profileQueriesAfterSelectionGate = Module._lfweb_profile_query_count();
    state.profileQueriesAfterSelectionGate.push(profileQueriesAfterSelectionGate);
    if (!selected) {
      state.lastSelection = "empty";
      resetRejectedSelection(FILE_ERROR);
      finishRead();
      return;
    }
    if (selected.size === 0) {
      state.lastSelection = "empty";
      resetRejectedSelection(FILE_ERROR);
      finishRead();
      return;
    }
    if (selected.size > MAX_CONTENT_BYTES) {
      state.lastSelection = "oversized";
      resetRejectedSelection(FILE_ERROR);
      finishRead();
      return;
    }

    try {
      const readGate = state.nextFileReadGate;
      state.nextFileReadGate = null;
      if (readGate) await new Promise(resolve => {
        state.activeFileReadRelease = resolve;
      });
      state.activeFileReadRelease = null;
      const profileQueriesBeforeRead = Module._lfweb_profile_query_count();
      if (state.reads === 0) {
        state.firstReadProfileQueriesBefore = profileQueriesBeforeRead;
        state.firstReadCountBefore = state.reads;
        state.firstReadProfileGateBefore =
          profileQueriesBeforeRead === profileQueriesAfterSelectionGate;
      }
      state.profileQueriesBeforeReads.push(profileQueriesBeforeRead);
      state.profileGateBeforeReads.push(
        profileQueriesBeforeRead === profileQueriesAfterSelectionGate,
      );
      state.reads += 1;
      const bytes = new Uint8Array(await selected.arrayBuffer());
      if (bytes.length === 0 || bytes.length > MAX_CONTENT_BYTES) {
        state.lastSelection = "size-changed";
        resetRejectedSelection(FILE_ERROR);
        finishRead();
        return;
      }
      if (Module.HEAPU8.buffer.byteLength === 0) {
        state.lastSelection = "consumer-unavailable";
        resetRejectedSelection(FILE_ERROR);
        finishRead();
        return;
      }
      Module.HEAPU8.set(bytes, Module._lfweb_content_buffer());
      state.wasmCopies += 1;
      state.loadStatus = Module._lfweb_load_buffer(bytes.length);
      state.lastLoadAccepted = Module._lfweb_content_loaded() === 1;
      if (!state.lastLoadAccepted || state.loadStatus !== 0) {
        state.lastSelection = "load-refused";
        resetRejectedSelection(FILE_ERROR);
        finishRead();
        return;
      }
      state.lastSelection = "loaded";
      resetSessionMetrics();
      state.started = false;
      state.paused = false;
      state.stopped = false;
      state.runtimeError = false;
      clearCanvas();
      setStatus("File ready. Select Start session.");
      finishRead();
    } catch {
      state.lastSelection = "read-failed";
      resetRejectedSelection(FILE_ERROR);
      finishRead();
    }
  }

  function report() {
    return {
      ready: state.ready,
      profile_first: state.profileValidated,
      selections: state.selections,
      last_selection: state.lastSelection,
      reads: state.reads,
      wasm_copy_count: state.wasmCopies,
      first_read_profile_queries_before: state.firstReadProfileQueriesBefore,
      first_read_count_before: state.firstReadCountBefore,
      first_read_profile_gate_before: state.firstReadProfileGateBefore,
      profile_queries_before_reads: [...state.profileQueriesBeforeReads],
      profile_gate_before_reads: [...state.profileGateBeforeReads],
      profile_queries_after_selection_gate: [...state.profileQueriesAfterSelectionGate],
      initialize_profile_queries: state.initializeProfileQueries,
      profile_queries: Module._lfweb_profile_query_count(),
      copies: Module._lfweb_content_copy_count(),
      loads: Module._lfweb_load_call_count(),
      advances: Module._lfweb_advance_call_count(),
      progress: Module._lfweb_progress(),
      input_buttons: state.inputButtons,
      input_samples: [...state.inputSamples],
      input_transition_calls: Module._lfweb_input_transition_count(),
      audio_frames_produced: state.audioFramesProduced,
      audio_oracle_frames_verified: state.audioOracleFramesVerified,
      audio_oracle_last_valid: state.audioOracleLastValid,
      audio_buffer_history: [...state.audioBufferHistory],
      audio_queue_frames: state.audioQueue.length,
      audio_queue_samples: audioQueueSamples(),
      audio_queue_peak_frames: state.audioQueuePeakFrames,
      audio_queue_peak_samples: state.audioQueuePeakSamples,
      audio_sources_stopped: state.audioSourcesStopped,
      last_load_status: state.loadStatus,
      last_load_accepted: state.lastLoadAccepted,
      content_loaded: Module._lfweb_content_loaded() === 1,
      instance_created: Module._lfweb_instance_create_count() > 0,
      destroy_calls: Module._lfweb_destroy_call_count(),
      trusted_start: state.trustedStart,
      user_activation: state.userActivation,
      start_attempts: state.startAttempts,
      audio_rate: state.audioRate,
      audio_graph_rms: state.audioRms,
      audio_context_state: state.audioContext ? state.audioContext.state : "none",
      audio_resume_pending: state.audioResumePending,
      audio_context_creations: state.audioContextsCreated,
      audio_active: state.activeAudio,
      stale_callback_captured: state.staleCallbackCaptured,
      stale_callback_invoked: state.staleCallbackInvoked,
      frame_callback_pending: state.pendingFrameCallback !== null,
      started: state.started,
      paused: state.paused,
      stopped: state.stopped,
      file_read_pending: state.fileReadPending,
      runtime_error: state.runtimeError,
      visibility_state: document.visibilityState,
      document_hidden: document.hidden,
      visibility_events: [...state.visibilityEvents],
      lifecycle: [...state.lifecycle]
    };
  }

  function rawFrame() {
    const pointer = Module._lfweb_video_buffer();
    return Array.from(Module.HEAPU8.subarray(pointer, pointer + PIXELS));
  }

  function canvasPixels() {
    return Array.from(context.getImageData(0, 0, WIDTH, HEIGHT).data);
  }

  function canvasBlank() {
    const rgba = context.getImageData(0, 0, WIDTH, HEIGHT).data;
    const backgroundAlpha = rgba[3];
    if (backgroundAlpha !== 0 && backgroundAlpha !== 255) return false;
    for (let at = 0; at < rgba.length; at += 4) {
      if (rgba[at] !== 0 || rgba[at + 1] !== 0 || rgba[at + 2] !== 0 ||
          rgba[at + 3] !== backgroundAlpha) {
        return false;
      }
    }
    return true;
  }

  function fixtureBytes() {
    const length = Module._lfweb_fixture_size();
    const pointer = Module._lfweb_fixture_buffer();
    return Array.from(Module.HEAPU8.subarray(pointer, pointer + length));
  }

  function applyInput(buttons) {
    if (!state.started || state.stopped || (state.paused && buttons !== 0) ||
        state.inputButtons === buttons) return;
    const status = Module._lfweb_set_input(buttons);
    if (status !== 0) throw new Error("public input transition failed");
    state.inputButtons = buttons;
  }

  function clearHeldInput() {
    heldKeys.clear();
    if (state.inputButtons !== 0) applyInput(0);
  }

  function heldButtonMask() {
    let buttons = 0;
    for (const key of heldKeys) buttons |= KEY_BUTTONS.get(key) ?? 0;
    return buttons;
  }

  function createRationalFrameGate() {
    let nextDeadline = null;
    return {
      due(timestampMs) {
        if (!Number.isFinite(timestampMs) || timestampMs < 0) return false;
        const now = BigInt(Math.round(timestampMs * 1000)) * FRAME_DENOMINATOR;
        if (nextDeadline === null) nextDeadline = now;
        if (now < nextDeadline) return false;
        // Carry the rational phase forward. If we missed deadlines, resume one interval
        // after this callback instead of running catch-up work.
        const followingDeadline = nextDeadline + FRAME_STEP_SCALED_MICROSECONDS;
        nextDeadline = followingDeadline <= now
          ? now + FRAME_STEP_SCALED_MICROSECONDS
          : followingDeadline;
        return true;
      },
    };
  }

  function schedulerProbe() {
    const gate = createRationalFrameGate();
    const timestamps = [0, 10, 17, 20, 34];
    const due = timestamps.map(timestamp => gate.due(timestamp));
    const displayGate = createRationalFrameGate();
    let displayAdvances = 0;
    for (let index = 0; index <= 60; index += 1) {
      if (displayGate.due(index * 1000 / 60)) displayAdvances += 1;
    }
    const delayedGate = createRationalFrameGate();
    const delayedOnce = delayedGate.due(0) && delayedGate.due(100);
    const delayedNext = delayedGate.due(100.01);
    let busy = false;
    let advances = 0;
    let active = 0;
    let maxConcurrent = 0;
    let reentrantRejected = false;
    const advance = () => {
      if (busy) {
        reentrantRejected = true;
        return;
      }
      busy = true;
      active += 1;
      maxConcurrent = Math.max(maxConcurrent, active);
      advances += 1;
      if (advances === 1) advance();
      active -= 1;
      busy = false;
    };
    for (const isDue of due) {
      if (isDue) advance();
    }
    return {
      due,
      sixty_hz_advances: displayAdvances,
      advances,
      maxConcurrent,
      delayed_once: delayedOnce,
      delayed_next_due: delayedNext,
      reentrant_rejected: reentrantRejected,
    };
  }

  function audioQueueSamples() {
    return state.audioQueue.reduce((total, entry) => total + entry.samples, 0);
  }

  function audioSampleCountMatches(frameIndex, sampleCount) {
    if (!Number.isInteger(sampleCount) || sampleCount <= 0 || sampleCount > 801) return false;
    if (frameIndex < ORACLE_AUDIO_SAMPLE_COUNTS.length) {
      return sampleCount === ORACLE_AUDIO_SAMPLE_COUNTS[frameIndex];
    }
    return sampleCount === 800 || sampleCount === 801;
  }

  function audioOracleProbe() {
    return {
      startup_count_valid: audioSampleCountMatches(0, 54),
      changed_startup_count_rejected: !audioSampleCountMatches(0, 55),
      steady_800_valid: audioSampleCountMatches(15, 800),
      steady_801_valid: audioSampleCountMatches(15, 801),
      changed_steady_count_rejected: !audioSampleCountMatches(15, 802),
    };
  }

  function refreshAudioQueueState() {
    const samples = audioQueueSamples();
    state.activeAudio = state.audioQueue.length > 0 &&
      state.audioContext?.state === "running";
    state.audioQueuePeakFrames = Math.max(state.audioQueuePeakFrames, state.audioQueue.length);
    state.audioQueuePeakSamples = Math.max(state.audioQueuePeakSamples, samples);
  }

  function retireAudioEntry(entry) {
    const index = state.audioQueue.indexOf(entry);
    if (index === -1) return;
    state.audioQueue.splice(index, 1);
    entry.retired = true;
    entry.source.onended = null;
    try { entry.source.stop(); } catch {}
    try { entry.source.disconnect(); } catch {}
    entry.source.buffer = null;
    state.audioSourcesStopped += 1;
    refreshAudioQueueState();
  }

  function retireAllAudio() {
    for (const entry of [...state.audioQueue]) retireAudioEntry(entry);
    state.nextAudioTime = state.audioContext?.currentTime ?? 0;
    state.activeAudio = false;
  }

  function captureAudioGraphActivity(audio) {
    if (!state.audioAnalyser || audio.state !== "running") return;
    const values = new Float32Array(state.audioAnalyser.fftSize);
    state.audioAnalyser.getFloatTimeDomainData(values);
    let sumSquares = 0;
    for (const value of values) sumSquares += value * value;
    state.audioRms = Math.max(state.audioRms, Math.sqrt(sumSquares / values.length));
  }

  function queuePublicAudio(audio) {
    if (!audio || audio.state !== "running" || audio.sampleRate !== 48000) {
      throw new Error("audio context is not running at the profile rate");
    }
    const frameIndex = state.audioFramesProduced;
    const sampleCount = Module._lfweb_audio_sample_count();
    if (!audioSampleCountMatches(frameIndex, sampleCount)) {
      throw new Error("public PCM sample count differs from the frozen Muhtari oracle");
    }
    const oracleValid = Module._lfweb_audio_oracle_valid() === 1;
    if (!oracleValid) throw new Error("public PCM failed the independent Muhtari oracle");
    state.audioOracleLastValid = true;
    state.audioOracleFramesVerified += 1;
    state.audioFramesProduced += 1;

    const pointer = Module._lfweb_audio_buffer();
    const samples = Module.HEAP16.slice(pointer >>> 1, (pointer >>> 1) + sampleCount);
    const buffer = audio.createBuffer(1, samples.length, 48000);
    if (buffer.sampleRate !== 48000 || buffer.numberOfChannels !== 1 ||
        buffer.length !== sampleCount) {
      throw new Error("browser created an AudioBuffer outside the profile format");
    }
    const channel = buffer.getChannelData(0);
    for (let index = 0; index < samples.length; index += 1) {
      channel[index] = samples[index] / 32768;
    }

    while (state.audioQueue.length >= 4 ||
        audioQueueSamples() + sampleCount > 3204) {
      retireAudioEntry(state.audioQueue[0]);
    }
    const source = audio.createBufferSource();
    source.buffer = buffer;
    source.loop = false;
    source.connect(state.audioAnalyser);
    const when = Math.max(audio.currentTime, state.nextAudioTime);
    const entry = { source, samples: sampleCount, when, retired: false };
    source.onended = () => {
      if (entry.retired) return;
      const index = state.audioQueue.indexOf(entry);
      if (index !== -1) state.audioQueue.splice(index, 1);
      entry.retired = true;
      source.onended = null;
      try { source.disconnect(); } catch {}
      source.buffer = null;
      refreshAudioQueueState();
    };
    state.audioQueue.push(entry);
    state.nextAudioTime = when + buffer.duration;
    state.audioRate = buffer.sampleRate;
    state.audioBufferHistory.push({
      sample_rate: buffer.sampleRate,
      channels: buffer.numberOfChannels,
      length: buffer.length,
    });
    if (state.audioBufferHistory.length > 64) state.audioBufferHistory.shift();
    if (state.nextAudioStartFailure) {
      state.nextAudioStartFailure = false;
      throw new Error("injected AudioBufferSource.start failure");
    }
    source.start(when);
    refreshAudioQueueState();
    captureAudioGraphActivity(audio);
  }

  function connectAudioGraph(audio) {
    if (state.audioAnalyser) return;
    const analyser = audio.createAnalyser();
    analyser.fftSize = 256;
    analyser.connect(audio.destination);
    state.audioAnalyser = analyser;
  }

  function advanceGuestFrame() {
    if (state.frameAdvancing || !state.started || state.paused || state.stopped ||
        !state.audioContext || state.audioContext.state !== "running") return false;
    state.frameAdvancing = true;
    try {
      const before = Module._lfweb_progress();
      const status = Module._lfweb_advance_once(state.inputButtons);
      if (status !== 0 || Module._lfweb_output_valid() !== 1 ||
          Module._lfweb_progress() !== before + 1 ||
          Module._lfweb_last_sampled_buttons() !== state.inputButtons) {
        throw new Error("public guest frame failed validation");
      }
      copyAndRenderFrame();
      queuePublicAudio(state.audioContext);
      state.inputSamples.push(Module._lfweb_last_sampled_buttons());
      if (state.inputSamples.length > 64) state.inputSamples.shift();
      return true;
    } finally {
      state.frameAdvancing = false;
    }
  }

  function scheduleGuestFrame(generation) {
    if (generation !== state.generation || state.paused || state.stopped || !state.started) return;
    const callback = timestamp => {
      if (generation !== state.generation || state.paused || state.stopped || !state.started) return;
      if (state.pendingFrameCallback === callback) state.pendingFrameCallback = null;
      try {
        if (state.nextRuntimeError) {
          state.nextRuntimeError = false;
          throw new Error("injected runtime failure");
        }
        if (state.frameGate.due(timestamp)) advanceGuestFrame();
        captureAudioGraphActivity(state.audioContext);
        scheduleGuestFrame(generation);
      } catch {
        state.runtimeError = true;
        pauseGuestLoop();
        clearHeldInput();
        retireAllAudio();
        if (!document.hidden) setStatus(RUNTIME_ERROR);
        updateControls();
      }
    };
    state.pendingFrameCallback = callback;
    state.frameHandle = requestAnimationFrame(callback);
  }

  function beginGuestLoop() {
    state.frameGate = createRationalFrameGate();
    state.paused = false;
    state.generation += 1;
    scheduleGuestFrame(state.generation);
  }

  function pauseGuestLoop() {
    state.generation += 1;
    if (state.frameHandle !== null) cancelAnimationFrame(state.frameHandle);
    state.frameHandle = null;
    state.pendingFrameCallback = null;
    state.paused = true;
  }

  function captureNextFrameCallback() {
    if (!state.started || state.paused || state.stopped ||
        typeof state.pendingFrameCallback !== "function") {
      return false;
    }
    state.capturedStaleFrameCallback = state.pendingFrameCallback;
    state.staleCallbackCaptured = true;
    return true;
  }

  function invokeCapturedStaleFrameCallback() {
    const callback = state.capturedStaleFrameCallback;
    state.capturedStaleFrameCallback = null;
    state.staleCallbackInvoked = callback !== null;
    if (callback) callback(performance.now());
  }

  function stopSession() {
    if (state.stopped) return false;

    // Invalidate callbacks before cancelling them or releasing anything they could use.
    state.generation += 1;
    if (state.frameHandle !== null) cancelAnimationFrame(state.frameHandle);
    state.frameHandle = null;
    state.pendingFrameCallback = null;
    state.paused = true;

    clearHeldInput();
    retireAllAudio();
    if (state.audioAnalyser) {
      try { state.audioAnalyser.disconnect(); } catch {}
      state.audioAnalyser = null;
    }

    state.started = false;
    state.frameGate = null;
    state.runtimeError = false;
    if (state.audioContext && state.audioContext.state === "running") {
      void state.audioContext.suspend();
    }

    if (Module._lfweb_destroy() !== 1) {
      state.runtimeError = true;
      setStatus(RUNTIME_ERROR);
      updateControls();
      return false;
    }

    state.stopped = true;
    state.lastLoadAccepted = false;
    clearCanvas();
    fileInput.value = "";
    setStatus("Session stopped. In-memory battery changes were discarded. Choose the A78 file again to start a new session.");
    updateControls();
    fileInput.focus();
    return true;
  }

  function observeAudioState(audio) {
    audio.addEventListener("statechange", () => {
      if (audio.state === "running") {
        state.audioResumePending = false;
        return;
      }
      if (!state.started || state.paused || state.stopped || state.audioResumePending) return;
      const wasAdvancing = !state.paused;
      pauseGuestLoop();
      clearHeldInput();
      retireAllAudio();
      if (wasAdvancing) state.lifecycle.push("audio-interrupted");
      if (!document.hidden) {
        setStatus("Audio was interrupted. Select Resume session to restart audio and continue.");
        updateControls();
      }
    });
  }

  async function onStart(event) {
    state.startAttempts += 1;
    if (!event.isTrusted || !navigator.userActivation?.isActive ||
        !state.lastLoadAccepted || state.stopped) {
      setStatus("Select a valid game before starting a session.");
      return;
    }
    const wasStarted = state.started;
    state.trustedStart = event.isTrusted;
    state.userActivation = navigator.userActivation.isActive;
    startButton.disabled = true;
    startButton.textContent = "Start session";
    try {
      let audio = state.audioContext;
      if (!audio || audio.state === "closed") {
        audio = new AudioContext({ sampleRate: 48000 });
        state.audioContext = audio;
        state.audioContextsCreated += 1;
        observeAudioState(audio);
      }
      state.audioResumePending = true;
      let resume;
      if (state.nextAudioResumeFailure) {
        state.nextAudioResumeFailure = false;
        resume = Promise.reject(new Error("injected AudioContext.resume failure"));
      } else {
        resume = audio.resume();
      }
      if (audio.sampleRate !== 48000) throw new Error("audio context rate differs from the profile");
      await resume;
      state.audioResumePending = false;
      if (audio.state !== "running") throw new Error("audio context did not enter running state");
      connectAudioGraph(audio);
      if (!state.started) {
        state.started = true;
        state.paused = false;
        state.stopped = false;
        if (!advanceGuestFrame()) throw new Error("public guest advance failed");
        state.lifecycle.push("started");
      } else if (state.paused) {
        state.lifecycle.push("resumed");
      }
      beginGuestLoop();
      updateControls();
      canvas.focus();
      setStatus("Running.");
    } catch {
      state.audioResumePending = false;
      pauseGuestLoop();
      clearHeldInput();
      state.started = wasStarted;
      state.paused = wasStarted;
      retireAllAudio();
      if (state.audioContext && state.audioContext.state === "running") {
        try { await state.audioContext.suspend(); } catch {}
      }
      state.lifecycle.push(wasStarted ? "resume-failed" : "start-failed");
      setStatus(wasStarted ? RESUME_ERROR : START_ERROR);
      updateControls();
    }
  }

  function onPause() {
    if (!state.started || state.paused || state.stopped || state.runtimeError) return;
    pauseGuestLoop();
    clearHeldInput();
    retireAllAudio();
    if (state.audioContext && state.audioContext.state === "running") {
      void state.audioContext.suspend();
    }
    setStatus("Paused. Select Resume session to continue.");
    updateControls();
  }

  function onVisibilityChange() {
    state.visibilityEvents.push(document.visibilityState);
    state.lifecycle.push(document.hidden ? "hidden" : "visible");
    if (document.hidden && state.started) {
      pauseGuestLoop();
      clearHeldInput();
      retireAllAudio();
      if (state.audioContext && state.audioContext.state === "running") {
        void state.audioContext.suspend();
      }
      setStatus("Session paused because this page was hidden. Return and select Resume session to continue.");
      updateControls();
    } else if (!document.hidden && state.started && state.paused) {
      setStatus("Paused. Select Resume session to continue.");
      updateControls();
    }
  }

  function onPageHide(event) {
    state.lifecycle.push(event.persisted ? "pagehide-persisted" : "pagehide");
    pauseGuestLoop();
    clearHeldInput();
    retireAllAudio();
    if (state.audioContext && state.audioContext.state === "running") {
      void state.audioContext.suspend();
    }
  }

  function onPageShow(event) {
    state.lifecycle.push(event.persisted ? "pageshow-persisted" : "pageshow");
    if (event.persisted && state.started) {
      state.paused = true;
      setStatus("Paused. Select Resume session to continue.");
      updateControls();
    }
  }

  document.addEventListener("visibilitychange", onVisibilityChange);
  window.addEventListener("pagehide", onPageHide);
  window.addEventListener("pageshow", onPageShow);
  fileInput.addEventListener("change", () => { void onFileChange(); });
  startButton.addEventListener("click", event => { void onStart(event); });
  pauseButton.addEventListener("click", onPause);
  stopButton.addEventListener("click", stopSession);
  canvas.addEventListener("blur", clearHeldInput);
  window.addEventListener("blur", clearHeldInput);
  canvas.addEventListener("keydown", event => {
    if (!KEY_BUTTONS.has(event.key)) return;
    event.preventDefault();
    if (event.repeat || heldKeys.has(event.key)) return;
    heldKeys.add(event.key);
    applyInput(heldButtonMask());
  });
  canvas.addEventListener("keyup", event => {
    if (KEY_BUTTONS.has(event.key)) {
      event.preventDefault();
      heldKeys.delete(event.key);
      applyInput(heldButtonMask());
    }
  });

  window.LibFuturoHost = {
    initialize() {
      if (!profileMatches()) throw new Error("the exact profile is unavailable");
      state.initializeProfileQueries = Module._lfweb_profile_query_count();
      state.ready = true;
      state.profileValidated = false;
    },
    report,
    holdNextFileRead() {
      if (state.nextFileReadGate || state.fileReadPending) return false;
      state.nextFileReadGate = { release: null };
      return true;
    },
    releaseFileRead() {
      const gate = state.nextFileReadGate;
      state.nextFileReadGate = null;
      const release = state.activeFileReadRelease;
      state.activeFileReadRelease = null;
      if (release) release();
      return gate !== null || release !== null;
    },
    failNextFrameForTest() {
      if (!state.started || state.paused || state.stopped) return false;
      state.nextRuntimeError = true;
      return true;
    },
    failNextAudioStartForTest() {
      state.nextAudioStartFailure = true;
      return true;
    },
    failNextAudioResumeForTest() {
      if (!state.started || !state.paused || !state.audioContext) return false;
      state.nextAudioResumeFailure = true;
      return true;
    },
    schedulerProbe,
    audioOracleProbe,
    audioContext: () => state.audioContext,
    rawFrame,
    canvasPixels,
    canvasBlank,
    fixtureBytes,
    captureNextFrameCallback,
    invokeCapturedStaleFrameCallback,
    stopSession
  };
})();
