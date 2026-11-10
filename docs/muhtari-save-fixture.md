# Muhtari battery save fixture and commit evidence

This record separates the pinned upstream diagnostic's provenance from
libfuturo's independently authored byte and progress expectations. The
installed consumer exercises the public API against moved installed artifacts;
the upstream test description is source context, not execution evidence.

## Fixture provenance and topology

| Property | Value |
|---|---|
| Muhtari core source commit | `d5fd241e3f4d701d73867cc2e465c56a6fe6793d` |
| Battery diagnostic source commit | `4642ded6d026f456acf798a43efb081b76987018` |
| Fixture manifest SHA-256 | `10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4` |
| Fixture license | MIT |
| Fixture image extent | 16,512 bytes |
| Selected configuration | `muhtari-ntsc-battery-diagnostic` |
| Device topology | NTSC, no BIOS, joystick on Muhtari port 1, HSC plus SaveKey on Muhtari port 2 |
| Aggregate media | `muhtari-battery-v1`, exactly 34,816 bytes when loaded |

The manifest digest identifies upstream fixture provenance; it is not the
independent save oracle or a claim of authenticity. The relocation route stages
the pinned diagnostic below ignored build output, records the fixture digest,
and does not add the ROM bytes to tracked files.

## Independent full-span oracle

[`muhtari_save_oracle.h`](../tests/installed-consumer/muhtari_save_oracle.h)
contains literal expectations authored separately from the fixture loader.
For both the 1/1 and 2/2 guest checkpoints, every byte in the 34,816-byte
aggregate is `0xFF` except these independently expected counter bytes:

| Aggregate offset | Device data | 1/1 | 2/2 |
|---:|---|---:|---:|
| `0x0100` | HSC counter low byte | `0x01` | `0x02` |
| `0x0101` | HSC counter high byte | `0x00` | `0x00` |
| `0x6800` | SaveKey EEPROM counter low byte | `0x01` | `0x02` |
| `0x6801` | SaveKey EEPROM counter high byte | `0x00` | `0x00` |

The offset derivation is source-derived from the exact pinned diagnostic and
layout documentation. The installed consumer verified the full 34,816-byte
aggregate at both the 1/1 and 2/2 checkpoints. The acceptance values remain
literal and independent; the consumer does not calculate expected bytes from
the fixture or its observed output. It compares the complete aggregate, not
only the four counter bytes.

## Envelope, commit point, and bounded failure case

The host-owned save envelope independently encodes its version and header size,
loaded-content digest, effective configuration
`muhtari-ntsc-battery-diagnostic`, media identity `muhtari-battery-v1`, exact
extent, and guest generation. The host copies core media into caller-owned
storage; it never persists or retains a Muhtari media pointer. Guest generation
is a core change token, not a host revision or durable acknowledgment.

The ordinary local commit stages the complete envelope and payload in a
temporary file in the destination directory, closes it, renames it over the
save, then reads back and compares the exact header, payload, and generation.
The consumer records success only after that exact readback.

The failure test writes a partial payload to a same-directory temporary file
and fails before rename. It verifies that the prior committed file and its
host acknowledgment remain byte-for-byte unchanged, the temporary file is
removed, and a distinct fresh process imports the previous 1/1 commit and
continues to the independent 2/2 expectation. The failed 2/2 copy and
generation are not acknowledged.

This is evidence for the controlled partial pre-rename staging failure and
ordinary rename commit point only. It does not establish power-loss or OS-crash
durability, post-rename failure recovery, damaged-storage repair, multi-writer
behavior, generalized interruption or retry guarantees, or cross-core save
portability.

## Executed scope

Run the relocated public-consumer journey on local macOS arm64:

```sh
sh tests/installed-consumer/relocate-consumer.sh --muhtari-save-restart
```

The route uses four separate invocations of the moved installed consumer: the
writer, committed fresh restorer, failed update, and fresh recovery. Its report
binds the process results to the Muhtari source pin, fixture provenance, moved
consumer executable, and installed libfuturo and Muhtari archives. A passing
run checks rejection without live-media mutation, the valid 1/1 restore and
2/2 continuation, and the prior-save recovery after the injected failure. It
qualifies only the selected local macOS arm64 profile and these ordinary
sequential process lifetimes.
