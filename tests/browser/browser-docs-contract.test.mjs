import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { SCENARIO_INVENTORY } from "./qualification.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const FILES = [
  "README.md",
  "docs/development.md",
  "docs/muhtari-profile.md",
  "docs/browser-host.md",
  "scripts/check-browser-package.sh",
  "tests/web-consumer/CMakeLists.txt",
];

function readInputs(overrides = {}) {
  const files = Object.fromEntries(FILES.map(file => [
    file,
    overrides[file] ?? readFileSync(path.join(ROOT, file), "utf8"),
  ]));
  return files;
}

function capture(text, expression, label) {
  const match = text.match(expression);
  if (!match) throw new Error(`could not read ${label} from the browser qualification inputs`);
  return match[1];
}

function shellConstant(script, name) {
  return capture(script, new RegExp(`readonly ${name}='([^']+)'`), name);
}

function cmakeArgument(script, name) {
  return capture(script, new RegExp(`-D${name}=([^\\s\\\\]+)`), name);
}

function routeIdentity(files) {
  const script = files["scripts/check-browser-package.sh"];
  const cmake = files["tests/web-consumer/CMakeLists.txt"];
  const fixtureMatch = script.match(
    /fixture_metadata:\s*\{\s*id:\s*\\?"([^"\\]+)\\?",\s*bytes:\s*(\d+),\s*sha256:\s*\\?"([a-f0-9]{64})\\?"/,
  );
  if (!fixtureMatch) throw new Error("could not read generated fixture metadata from the browser route");
  const identity = {
    coreVersion: cmakeArgument(script, "EXPECTED_MUHTARI_VERSION"),
    coreRevision: cmakeArgument(script, "EXPECTED_MUHTARI_SOURCE_REVISION"),
    apiRevision: cmakeArgument(script, "EXPECTED_MUHTARI_API_REVISION"),
    profile: cmakeArgument(script, "EXPECTED_PROFILE_ID"),
    configuration: cmakeArgument(script, "EXPECTED_CONFIGURATION_ID"),
    fixtureId: fixtureMatch[1],
    fixtureBytes: fixtureMatch[2],
    fixtureSha256: fixtureMatch[3],
    sdkImage: shellConstant(script, "SDK_IMAGE"),
    sdkPlatform: shellConstant(script, "SDK_PLATFORM"),
    browserVersion: shellConstant(script, "CFT_VERSION"),
    browserRevision: shellConstant(script, "CFT_REVISION"),
    browserArchiveSha256: shellConstant(script, "CFT_SHA256"),
    abiRevision: capture(cmake, /CORE_ABI_REVISION STREQUAL "([0-9]+)"/, "API 8 ABI revision"),
    behaviorRevision: capture(cmake, /CORE_BEHAVIOR_REVISION STREQUAL "([0-9]+)"/, "API 8 behavior revision"),
  };
  assert.match(identity.sdkImage, /@sha256:[a-f0-9]{64}$/,
    "the Emscripten image must remain digest-pinned");
  assert.equal(identity.sdkPlatform, "linux/amd64");
  assert.equal(identity.apiRevision, "8");
  assert.equal(identity.abiRevision, "1");
  assert.equal(identity.behaviorRevision, "6");
  assert.equal(identity.fixtureSha256,
    cmakeArgument(script, "EXPECTED_FIXTURE_SHA256"),
    "report fixture identity and relocated-consumer fixture input must agree");
  assert.match(script, /-sEXIT_RUNTIME=1[\s\S]*?-sEXIT_RUNTIME=0/,
    "the browser route must keep the exported C API runtime alive after main");
  assert.match(script, /browser-qualification\.json/,
    "the route must keep its aggregate report output name stable");
  assert.match(script, /LIBFUTURO_BROWSER_QUALIFICATION_EVIDENCE=\/work\/evidence\/qualification/,
    "the route must keep per-scenario evidence under the run evidence directory");
  assert.match(files["tests/web-consumer/CMakeLists.txt"], /"-sENVIRONMENT=web"/);
  assert.match(files["tests/web-consumer/CMakeLists.txt"], /"-sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16"/);
  return identity;
}

function localLinks(contents) {
  return [...contents.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)]
    .map(([, target]) => target)
    .filter(target => !/^[a-z][a-z0-9+.-]*:/i.test(target) && !target.startsWith("#"));
}

function validateDocumentation(files) {
  const errors = [];
  let identity;
  try {
    identity = routeIdentity(files);
  } catch (error) {
    errors.push(`qualification inputs: ${error.message}`);
    return errors;
  }
  const guide = files["docs/browser-host.md"];
  const normalizedGuide = guide.replace(/\s+/g, " ");
  const requirements = [
    ["canonical command", "./scripts/check-browser-package.sh"],
    ["core version", identity.coreVersion],
    ["core source revision", identity.coreRevision],
    ["API revision", `API ${identity.apiRevision}`],
    ["ABI revision", `ABI ${identity.abiRevision}`],
    ["behavior revision", `behavior ${identity.behaviorRevision}`],
    ["profile", identity.profile],
    ["configuration", identity.configuration],
    ["fixture id", identity.fixtureId],
    ["fixture extent", `${Number(identity.fixtureBytes).toLocaleString("en-US")} bytes`],
    ["fixture digest", identity.fixtureSha256],
    ["SDK image", identity.sdkImage],
    ["SDK platform", identity.sdkPlatform],
    ["browser product", "Chrome for Testing Headless Shell"],
    ["browser version", identity.browserVersion],
    ["browser revision", `revision \`${identity.browserRevision}\``],
    ["browser archive digest", identity.browserArchiveSha256],
    ["reported browser runtime inventory", "installed-unpinned"],
    ["identity assurance limit", "not authentication or attestation"],
    ["clean committed source", "A clean checkout is required"],
    ["lineage identity", "source commit"],
    ["actual web link environment", "-sENVIRONMENT=web"],
    ["exported heap views", "-sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16"],
    ["long-lived browser runtime", "-sEXIT_RUNTIME=0"],
    ["test launch sandbox flag", "--no-sandbox"],
    ["test launch GPU flag", "--disable-gpu"],
    ["aggregate success state", "qualification-pass"],
    ["diagnostic-only focused modes", "diagnostic-only"],
    ["scenario evidence", "host-input-audio"],
    ["aggregate report path", "build/browser-package/<run-id>/evidence/browser-qualification.json"],
    ["scenario report path", "evidence/qualification/"],
  ];
  for (const [label, value] of requirements) {
    if (!normalizedGuide.includes(value)) errors.push(`browser guide is missing ${label}: ${value}`);
  }
  for (const scenario of SCENARIO_INVENTORY) {
    if (!guide.includes(`\`${scenario}\``)) errors.push(`browser guide is missing scenario ${scenario}`);
  }

  const limitations = [
    ["generated fixture only", /generated fixture only/i],
    ["session-only battery", /battery[^.]{0,100}session.only|session.only[^.]{0,100}battery/i],
    ["no browser save or snapshot", /no browser[^.\n]{0,120}(?:save|snapshot)|browser[^.\n]{0,80}no (?:save|snapshot)/i],
    ["software audio graph only", /(?:web audio|audio)[^.]{0,100}graph.only|graph.only[^.]{0,100}audio/i],
    ["no physical speaker qualification", /does not qualify physical speakers|no physical speaker qualification/i],
    ["BFCache not qualified", /BFCache[^.]{0,100}(?:not qualified|unqualified|does not qualify)/i],
    ["no cross-browser qualification", /no cross.browser[^.]{0,100}qualification/i],
    ["no mobile qualification", /no mobile[^.]{0,100}qualification/i],
    ["no hardware qualification", /hardware qualification/i],
    ["no broad Wasm qualification", /broad Wasm[^.]{0,100}qualification/i],
    ["no stable ABI or release promise", /no stable ABI[^.]{0,100}promise|no[^.]{0,80}release promise/i],
  ];
  for (const [label, expression] of limitations) {
    if (!expression.test(normalizedGuide)) errors.push(`browser guide is missing accepted limitation: ${label}`);
  }

  for (const file of ["README.md", "docs/development.md", "docs/muhtari-profile.md"]) {
    const contents = files[file];
    const expectedTarget = file === "README.md" ? "docs/browser-host.md" : "browser-host.md";
    if (!localLinks(contents).includes(expectedTarget)) {
      errors.push(`${file} must link to ${expectedTarget}`);
    }
    if (file === "docs/muhtari-profile.md" && !/^## Browser execution qualification$/m.test(contents)) {
      errors.push("Muhtari profile must keep browser evidence in a separate Browser execution qualification section");
    }
    const normalizedContents = contents.replace(/\s+/g, " ");
    if (file === "docs/development.md" && !/does not replace the native macOS command/i.test(normalizedContents)) {
      errors.push("development guide must preserve the native and browser route distinction");
    }
    if (file === "docs/muhtari-profile.md" && !/does not expand the native snapshot contract/i.test(normalizedContents)) {
      errors.push("Muhtari profile must keep browser evidence separate from native snapshot behavior");
    }
  }

  for (const file of ["README.md", "docs/development.md", "docs/muhtari-profile.md", "docs/browser-host.md"]) {
    for (const target of localLinks(files[file])) {
      const relativeTarget = target.split("#", 1)[0];
      if (relativeTarget && !existsSync(path.resolve(path.dirname(path.join(ROOT, file)), relativeTarget))) {
        errors.push(`${file} has a broken local link: ${target}`);
      }
    }
  }

  if (!/qualification-pass/.test(guide) || !/all seven|all 7|seven scenarios/i.test(normalizedGuide)) {
    errors.push("browser guide must explain that the aggregate pass represents the complete seven-scenario route");
  }
  if (!/local[^.]{0,80}hosted|hosted[^.]{0,80}local/i.test(normalizedGuide)) {
    errors.push("browser guide must distinguish local runner evidence from hosted runner evidence");
  }
  if (!/source[^.]{0,80}not authentication|identity[^.]{0,80}not authentication/i.test(normalizedGuide)) {
    errors.push("browser guide must explain that recorded identity is not authenticity or attestation");
  }
  return errors;
}

test("browser guide records the exact route identity, scope, and entry-point links", () => {
  const errors = validateDocumentation(readInputs());
  assert.deepEqual(errors, [], errors.join("\n"));
});

test("documentation controls reject one-fault identity, link, and scope drift", () => {
  const guideInputs = readInputs();

  const changedCore = readInputs();
  changedCore["scripts/check-browser-package.sh"] =
    changedCore["scripts/check-browser-package.sh"].replace(
      "-DEXPECTED_MUHTARI_SOURCE_REVISION=d58f125297c4d63a7a8108112a5eafff6f53a76a",
      "-DEXPECTED_MUHTARI_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
  assert.ok(validateDocumentation(changedCore).some(error => error.includes("core source revision")),
    "a changed Muhtari source pin must be rejected against the unchanged guide");

  const changedBrowser = readInputs();
  changedBrowser["scripts/check-browser-package.sh"] =
    changedBrowser["scripts/check-browser-package.sh"].replace(
      "readonly CFT_VERSION='157.0.8103.50'",
      "readonly CFT_VERSION='158.0.8103.50'",
    );
  assert.ok(validateDocumentation(changedBrowser).some(error => error.includes("browser version")),
    "a changed browser pin must be rejected against the unchanged guide");

  const changedFixture = readInputs();
  changedFixture["scripts/check-browser-package.sh"] =
    changedFixture["scripts/check-browser-package.sh"].replaceAll(
      "136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
  assert.ok(validateDocumentation(changedFixture).some(error => error.includes("fixture digest")),
    "a changed generated-fixture digest must be rejected against the unchanged guide");

  const brokenEntryLink = readInputs();
  brokenEntryLink["README.md"] = brokenEntryLink["README.md"].replace(
    "docs/browser-host.md", "docs/missing-browser-host.md");
  assert.ok(validateDocumentation(brokenEntryLink).some(error => error.includes("README.md must link")),
    "a broken README guide link must be rejected");

  const missingSourceDistinction = readInputs();
  missingSourceDistinction["docs/browser-host.md"] = guideInputs["docs/browser-host.md"].replace(
    "A clean checkout is required, including no untracked files. The script refuses\na dirty checkout, records the source commit and tree, and builds from a\nread-only archive of that committed revision. This keeps the reported source\nidentity aligned with the files compiled by the container.",
    "The report includes source information.",
  );
  assert.ok(validateDocumentation(missingSourceDistinction).some(error =>
    error.includes("clean committed source") || error.includes("source commit")),
  "removing the committed-source distinction must be rejected");

  const missingLimitation = readInputs();
  missingLimitation["docs/browser-host.md"] = guideInputs["docs/browser-host.md"].replace(
    "Battery media is session-only and exists only in the live browser session. The route has no\n  browser save or snapshot path and does not qualify persistent battery or\n  machine-state recovery. Native snapshot evidence is described separately in\n  the [Muhtari profile](muhtari-profile.md); it does not transfer to this route.",
    "Battery media is exercised by the browser route.",
  );
  assert.ok(validateDocumentation(missingLimitation).some(error =>
    error.includes("session-only battery") || error.includes("no browser save or snapshot")),
  "omitting the browser battery and persistence limits must be rejected");
});
