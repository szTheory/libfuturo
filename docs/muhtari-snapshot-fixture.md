# Muhtari API 8 snapshot fixture and replay oracle

This fixture is a project-generated A78 program for the selected API 8 profile
`muhtari-ntsc-v2` with `muhtari-ntsc-battery-diagnostic`. It gives the source
and relocated installed public consumers a deterministic HSC plus SaveKey
state, a public-frame pending-write boundary, and fixed output oracles for
snapshot capture and restore.

## Provenance and topology

| Property | Value |
|---|---|
| Generator | `tests/installed-consumer/muhtari_snapshot_fixture.h` |
| Image format | A78 v1, linear 16 KiB ROM, generated in memory; no ROM file or downloaded bytes |
| Image extent | 16,512 bytes (128-byte header plus 16,384-byte ROM) |
| Image SHA-256 | `136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e` |
| Effective configuration | `muhtari-ntsc-battery-diagnostic` |
| Battery topology | HSC first (2,048 bytes), SaveKey EEPROM second (32,768 bytes) |
| Aggregate extent | 34,816 bytes (`muhtari-battery-v1`) |
| Fixture license | Generated project content follows the repository Apache-2.0 license |
| Protocol reference | SaveKey pin sequence adapted from the MIT-licensed Muhtari v0.11.1 test helper at source `d58f125297c4d63a7a8108112a5eafff6f53a76a`, `tests/core/test_state.c` |

The guest sends a SaveKey page write of `0x5A` to EEPROM word address 3 from its
one-time `$F000` preamble, then jumps to `$C000`. A short instruction-counted
delay positions the device busy interval near a public frame boundary. The
`$C000` loop sets a fixed background and tone, increments HSC CPU address
`$1100` (aggregate HSC offset `0x0100`), and repeats. The image builder and
guest code are maintained in this repository; the upstream test is protocol
reference only, and no upstream ROM bytes are copied.

## Fixed public replay vector

The consumer advances three frames through `lf_set_input`, `lf_advance`, and
`lf_copy_media`. It compares the complete 34,816-byte media span against an
independent array whose default is literal `0xFF`, then sets only the expected
HSC and EEPROM offsets below. Video hashes cover all 320 by 242 INDEX8 bytes;
PCM hashes encode each S16 sample in canonical little-endian order.

| Public frame | Audio samples | INDEX8 SHA-256 | PCM SHA-256 | Battery SHA-256 | HSC `0x0100` | EEPROM local `0x0003` (aggregate offset 2051) | Generation |
|---:|---:|---|---|---|---:|---:|---:|
| 1 | 54 | `a2039dfec6c6b253a800d8f2a22c917aee174787618bf83508d04408901840fa` | `77133f431d5e12dd850002c0d3d4e0fecbe3a7a699d604dc8c5eae9976e1d260` | `526d5e5ef52a683b7c1b56bd4f930811aa8d7217114a21fa2270c581382d63cc` | `FF` | `FF` | 0 |
| 2 (R2) | 801 | `40290f536a0e1b2540d868d1a8d2f88c59a0e2d072e49bac762678f245fbb79a` | `d4f75a98b2ac3685eae765036512f04f70d8c952340d8347f602c4b43c1ed15c` | `036d171c7642abeb0acc3670afc5a67422bf028b0086d0d8720a95985fdfdb64` | `43` | `FF` | 836 |
| 3 (R3) | 801 | `59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225` | `09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f` | `495ead1f5e803049666b25490aa47495e529eda7c8516eb3513947b403b4a583` | `37` | `5A` | 4153 |

For the full-span expectations, all bytes are `0xFF` except:

- R2: aggregate HSC offset `0x0100` is `0x43`; EEPROM offset 2051 remains `0xFF` while the page is pending.
- R3: aggregate HSC offset `0x0100` is `0x37`; EEPROM offset 2051 is `0x5A` after page publication.

The EEPROM's local word address is `0x0003`; aggregate offset 2051 is `2048 + 3`.
The first frame is a startup interval (54 audio samples), so later replay checks
use R2/frame 2 and R3/frame 3. Muhtari exposes no source tick count; this record
uses public frame units only.

## Boundary experiment and negative controls

The generated preamble uses a 100-iteration outer loop and a 46-iteration inner
loop before the SaveKey packet. The selected public schedule observes the
pending R2 state at frame 2 and the published `0x5A` at frame 3. The fixture
boundary test and its separate oracle-control test each execute the same public
schedule in a new consumer process; both observe the same frame, video, audio,
full-span battery, and generation literals. A direct source-consumer run
reproduced the same vector.

`muhtari_api8_fixture_oracle_controls` deliberately changes the expected frame
count, video digest, PCM digest, and full battery array one at a time. Each
control is rejected at its corresponding assertion after the ordinary
forward-run vector passes. The tests do not inspect Muhtari private state to
establish the pending boundary.

These results qualify only this generated fixture, selected configuration,
Muhtari API 8 pin, and public frame schedule. They do not claim other SaveKey
transactions, controllers, profiles, or cores.

## Snapshot contract established here

The API 8 snapshot capability query reports availability for the battery
diagnostic profile/configuration and does not inspect loaded content. Size,
capture, and restore additionally require this exact 16,512-byte fixture digest
and the verified 34,816-byte HSC/SaveKey topology. The caller owns a bounded
416-byte identity/continuation header followed by the exact
topology-sized Muhtari API 8 state; capture writes that prefix and leaves any
caller suffix untouched. The envelope records the LibFuturo build fingerprint,
Muhtari source pin and API/ABI/behavior/state-format tuple, effective profile,
configuration and options, content identity, frame count, pending buttons,
halt state, and same-instance load provenance. Version 2 includes a SHA-256
digest over the entire header with the digest field zeroed, covering metadata
including instance identity and successful-load epoch. This detects header
corruption but does not authenticate snapshots.

The source and moved-installed public routes each run a fresh-process A/B
journey using their own checkpoint and artifact identities. The route tests are
`muhtari_api8_source_fresh_process` and
`muhtari_api8_installed_fresh_process`. Process A captures
R2 after frame 2 with the SaveKey page pending, advances until frame 3
publishes `0x5A`, commits host-selected save R3, closes the checkpoint
successfully, and exits orderly. Fresh Process B reopens that exact checkpoint,
loads the matching profile/configuration/content/build, imports selected R3
before positive guest work, and restores R2. The pending page then publishes
at frame 3, where independent frame, video, audio, and complete battery-span
oracles are checked. Both routes verify outer-envelope refusals and a
checksum-valid native semantic-invalid state while preserving B's continuation,
full battery span, B-local generation, selected R3 bytes, and acknowledgment.

Restoring changed battery bytes advances B's own generation by one; restoring
identical bytes does not change it. The producer's saved generation is not
copied into B. Restore and a controlled pre-rename save replacement failure
preserve selected R3 and its acknowledgment. The host advances that
acknowledgment only after an explicit commit of restored media is reopened and
verified for identity, header, exact extent, and full payload. The host owns
checkpoint/save file I/O and durability decisions. These routes establish
successful checkpoint close, orderly process exit, and fresh-process reopen;
they do not establish crash, abrupt-exit, `fsync`, power-loss, or uncertain
post-rename recovery, authenticated snapshots, stable API/ABI/native state
format, or cross-build portability.
