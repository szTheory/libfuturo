const assert = require("node:assert/strict");
const path = require("node:path");

async function main() {
  if (process.argv.length !== 3) {
    throw new Error("usage: snapshot_identity_probe.cjs <emscripten-module>");
  }

  const createModule = require(path.resolve(process.argv[2]));
  const originalDateNow = Date.now;
  Date.now = () => 1_700_000_000_000;

  let producer;
  let receiver;
  try {
    [producer, receiver] = await Promise.all([
      createModule({ noInitialRun: true }),
      createModule({ noInitialRun: true }),
    ]);

    assert.equal(producer._lf_web_snapshot_capture_current(), 0,
      "producer instance and snapshot should initialize");
    const extent = producer._lf_web_snapshot_size();
    assert.ok(extent > 0 && extent <= 128 * 1024 * 1024,
      "captured snapshot extent should be bounded");
    const source = producer._lf_web_snapshot_pointer();
    const snapshot = producer.HEAPU8.slice(source, source + extent);
    const producerIdentityPointer =
      producer._lf_web_snapshot_identity_pointer();
    const producerIdentity = Buffer.from(producer.HEAPU8.slice(
      producerIdentityPointer,
      producerIdentityPointer + 32,
    ));

    assert.equal(receiver._lf_web_snapshot_prepare_receiver(), 0,
      "separate Wasm runtime should create the same qualified profile");
    assert.equal(receiver._lf_web_snapshot_reload_receiver(), 0,
      "receiver should advance to a later successful-load epoch");
    const receiverIdentityPointer =
      receiver._lf_web_snapshot_identity_pointer();
    const receiverIdentity = Buffer.from(receiver.HEAPU8.slice(
      receiverIdentityPointer,
      receiverIdentityPointer + 32,
    ));
    assert.notEqual(producerIdentity.toString("hex"),
      receiverIdentity.toString("hex"),
      "separate Wasm runtimes must receive distinct instance identities");
    const destination = receiver._lf_web_snapshot_import_buffer(extent);
    assert.ok(destination > 0, "receiver should allocate the snapshot span");
    receiver.HEAPU8.set(snapshot, destination);

    assert.equal(receiver._lf_web_snapshot_restore_import(extent), 0,
      "qualified cross-runtime restore should survive the receiver's later load epoch");
    console.log(
      "web_snapshot_identity: separate-wasm-runtimes=distinct later-load-epoch=restored fixed-wall-clock=pass result=pass",
    );
  } finally {
    producer?._lf_web_snapshot_dispose();
    receiver?._lf_web_snapshot_dispose();
    Date.now = originalDateNow;
  }
}

main().catch((error) => {
  console.error(`web_snapshot_identity: ${error.message}`);
  process.exitCode = 1;
});
