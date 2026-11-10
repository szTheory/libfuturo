#ifndef LIBFUTURO_LIBFUTURO_H
#define LIBFUTURO_LIBFUTURO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lf_instance lf_instance;

/* Status meanings and operation postconditions: LC-ERROR-01. */
typedef enum lf_status {
  LF_OK = 0,
  LF_INVALID_ARGUMENT = 1,
  LF_UNSUPPORTED = 2,
  LF_LIMIT_EXCEEDED = 3,
  LF_BUFFER_TOO_SMALL = 4,
  LF_RESOURCE_EXHAUSTED = 5
} lf_status;

typedef enum lf_capability {
  LF_CAP_LOGICAL_INPUT = 1,
  LF_CAP_BOUNDED_EXECUTION = 2,
  LF_CAP_SOFTWARE_VIDEO = 3,
  LF_CAP_AUDIO = 4,
  LF_CAP_IN_MEMORY_MEDIA_COPY = 5,
  LF_CAP_SNAPSHOT = 6,
  LF_CAP_HARDWARE_VIDEO = 7,
  LF_CAP_CONCURRENT_USE = 8
} lf_capability;

typedef enum lf_time_unit {
  LF_TIME_SYNTHETIC_STEP = 1,
  /* One completed profile frame-advance interval. The initial interval may
     be shorter than later intervals; this is guest-work progress, not an
     assertion that every unit has equal elapsed duration. */
  LF_TIME_FRAME = 2,
  /* Source-reported cumulative NES ticks, in half-master-clock periods. */
  LF_TIME_NES_HALF_MASTER_TICK = 3
} lf_time_unit;

typedef enum lf_input_sampling {
  LF_INPUT_AT_ADVANCE_START = 1
} lf_input_sampling;

typedef enum lf_video_format {
  LF_VIDEO_GRAY8 = 1,
  LF_VIDEO_RGB24 = 2,
  LF_VIDEO_INDEX8 = 3
} lf_video_format;

typedef enum lf_audio_encoding {
  LF_AUDIO_S16_NATIVE = 1
} lf_audio_encoding;

typedef enum lf_audio_layout {
  LF_AUDIO_INTERLEAVED = 1
} lf_audio_layout;

typedef enum lf_stop_reason {
  LF_STOP_BUDGET_REACHED = 1,
  LF_STOP_REJECTED = 2,
  LF_STOP_CORE_HALTED = 3
} lf_stop_reason;

typedef void *(*lf_allocate_fn)(void *context, size_t bytes);
typedef void (*lf_deallocate_fn)(void *context, void *allocation);

typedef struct lf_create_options {
  size_t struct_size;
  lf_allocate_fn allocate;
  lf_deallocate_fn deallocate;
  void *allocator_context;
} lf_create_options;

typedef struct lf_input {
  size_t struct_size;
  /* synthetic-v1 uses bits 0-1. nesturbator-ntsc-v1 uses bits 0-7 for
     port 0 (A, B, Select, Start, Up, Down, Left, Right) and bits 8-15 for
     port 1 in the same order. muhtari-ntsc-v1 uses bit 0 and bits 4-7 for
     port 0 (Button 1, Up, Down, Left, Right) and bits 8, 12-15 for port 1. */
  uint32_t buttons;
} lf_input;

typedef struct lf_load_request {
  size_t struct_size;
  const void *content_data;
  size_t content_size_bytes;
  /* NULL selects the profile's default configuration. */
  const char *configuration_id;
} lf_load_request;

typedef struct lf_load_result {
  size_t struct_size;
  uint32_t loaded;
  size_t content_size_bytes;
  const char *effective_configuration_id;
} lf_load_result;

/* Host precondition: the declared video and audio destination spans must be
 * disjoint from each other, request/result records, and instance storage.
 * Aliasing those spans is invalid caller use; runtime detection is not promised.
 * Adjacent, non-overlapping spans in one allocation are permitted. */
typedef struct lf_run_request {
  size_t struct_size;
  uint32_t work_units;
  uint8_t *video_data;
  size_t video_capacity_bytes;
  size_t video_stride_bytes;
  int16_t *audio_data;
  size_t audio_capacity_samples;
} lf_run_request;

typedef struct lf_run_result {
  size_t struct_size;
  uint32_t requested_units;
  uint32_t actual_units;
  uint32_t overshoot_units;
  uint32_t sampled_buttons;
  uint32_t video_valid;
  uint32_t audio_valid;
  /* Completed work in `time_unit`; for the real profile this is frames. */
  uint64_t cumulative_units;
  /* Cumulative source-reported guest ticks; validity is independent of frames. */
  uint32_t core_ticks_valid;
  uint64_t cumulative_core_ticks;
  lf_time_unit time_unit;
  lf_time_unit core_tick_time_unit;
  lf_stop_reason stop_reason;
  lf_video_format video_format;
  lf_audio_encoding audio_encoding;
  lf_audio_layout audio_layout;
  uint32_t video_width;
  uint32_t video_height;
  uint32_t audio_rate_numerator;
  uint32_t audio_rate_denominator;
  uint32_t audio_channels;
  size_t video_stride_bytes;
  size_t video_extent_bytes;
  size_t audio_produced_samples;
} lf_run_result;

typedef struct lf_media_info {
  size_t struct_size;
  /* Immutable library-owned string, valid until this instance is destroyed
     or the linked library code is unloaded, whichever happens first. */
  const char *identity;
  size_t extent_bytes;
  /* Profile-defined guest media change token. The profile specifies how
     guest work, imports, and snapshot restores affect it; it is not a host
     save revision or durability acknowledgment. */
  uint64_t guest_generation;
} lf_media_info;

typedef struct lf_profile {
  size_t struct_size;
  const char *profile_id;
  const char *core_id;
  const char *build_id;
  uint32_t api_revision;
  uint32_t behavior_revision;
  uint32_t input_mask;
  uint32_t max_work_units;
  uint32_t max_guest_units;
  uint32_t atomic_quantum_units;
  uint32_t max_overshoot_units;
  lf_time_unit time_unit;
  lf_input_sampling input_sampling;
  lf_video_format video_format;
  lf_audio_encoding audio_encoding;
  lf_audio_layout audio_layout;
  uint32_t video_width;
  uint32_t video_height;
  uint32_t video_bytes_per_pixel;
  uint32_t audio_rate_numerator;
  uint32_t audio_rate_denominator;
  uint32_t audio_channels;
  size_t min_video_stride_bytes;
  size_t max_audio_samples_per_call;
  /* Zero means this profile's exact media extent depends on the loaded content;
     successful lf_copy_media calls report the loaded extent. */
  size_t media_extent_bytes;
  size_t max_content_bytes;
  const char *effective_configuration_id;
  /* Exact steady-state frame rate when declared. Both are positive integers,
     or both are zero when cadence is undeclared or inapplicable. */
  uint32_t frame_rate_numerator;
  uint32_t frame_rate_denominator;
} lf_profile;

/* Profile values and bounds are profile-owned: LC-LIMIT-01. */
lf_status lf_get_profile(const char *profile_id, const char *configuration_id,
                         lf_profile *out);
/* Reports profile/configuration availability; this query does not inspect a
   live instance or its loaded content. Muhtari API 8 snapshot operations can
   still return LF_UNSUPPORTED when loaded content is outside the qualified
   fixture. */
lf_status lf_get_capability(const char *profile_id,
                            const char *configuration_id,
                            lf_capability capability, uint32_t *supported);
/* Snapshot bytes are opaque, caller-owned spans. Ordinary validity is limited
   to the same live instance, profile/effective configuration, core build,
   native state format, and successful-load session. Serialize calls on one
   instance. Query the exact extent after each successful load; capture writes
   only that extent, and size discovery, capture, and restore do not advance
   guest execution.

   The qualified battery-free fresh-process exception applies only to
   Nesturbator v0.1.12/source 2338608ab184f040620a30d17756f5e06a42d4e3,
   profile nesturbator-ntsc-v1, effective configuration
   nesturbator-default, options nesturbator-options-none-v1, and the exact
   generated 24,592-byte battery-free NROM content with SHA-256 digest
   e74fae7b6d5d8438e7f0c36f3b86f52eab426166b521bb923a8d93bf6d628235.
   Qualification is local macOS arm64, through the source and relocated
   installed consumers. Stable identity must match the LFSNAP2 envelope
   version, exact LibFuturo and core build IDs, core ABI/behavior revision,
   native state
   format, profile/configuration/options, and exact content extent/digest. The
   successful-load epoch rejects snapshots from stale successful loads on the
   same instance; it is not cross-process identity. Process A must successfully
   write and close the host-owned checkpoint and exit orderly before Process B
   reopens and verifies those bytes, loads a fresh instance, and restores. The
   host owns checkpoint I/O.

   The separate battery-backed fresh-process exception applies only to
   Nesturbator v0.1.12/source 2338608ab184f040620a30d17756f5e06a42d4e3,
   build nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3, API revision
   1, behavior revision 9, native state format 3, profile
   nesturbator-ntsc-v1, effective configuration nesturbator-default, options
   nesturbator-options-none-v1, and the exact generated 40,976-byte
   battery-backed MMC1 content with SHA-256 digest
   2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9.
   Qualification requires distinct source and relocated installed public
   consumers on local macOS arm64. The ordinary same-instance/session rule
   continues to apply to all other snapshots; other battery layouts, profiles,
   builds, and targets do not inherit this exception.

   In the battery-backed route, Process A captures S2 while guest media is
   R2, commits the newer selected save R3, closes the host-owned checkpoint,
   and exits orderly. Process B loads matching content, imports R3 before
   positive guest work, and restores S2 to R2. The epoch is B-local: changed
   restored bytes increase its generation by exactly one, while an identical
   repeat leaves it unchanged. Restore and a pre-rename staging-write failure
   preserve the selected R3 bytes and host acknowledgment. The host advances
   that acknowledgment to R2 only after an explicit successful commit is
   reopened and verified for identity, header, extent, and complete payload.
   Literal replay after restore produces R3 guest bytes again. These claims
   do not cover abrupt exit, crash, power loss, fsync, uncertain post-rename
   recovery, a stable ABI or snapshot format, general portability, other
   cores, hardware or browser qualification, or authentication.

   A separate API 8 battery-backed exception is qualified for Muhtari v0.11.1
   at source d58f125297c4d63a7a8108112a5eafff6f53a76a (API 8, ABI 1,
   behavior revision 6, native state format 1), profile muhtari-ntsc-v2,
   configuration muhtari-ntsc-battery-diagnostic, and no additional options.
   The project-generated 16,512-byte A78 fixture has SHA-256
   136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e and
   exactly 34,816 bytes of HSC plus SaveKey media. The capability query reports
   availability for the explicit battery-diagnostic configuration; because it
   does not inspect loaded content, snapshot operations separately require this
   exact fixture and media topology. Process A captures R2 after public
   frame 2 while the SaveKey write to aggregate offset 2051 is pending; capture
   does not advance guest work. The fresh Process B imports selected save R3
   before positive guest work, restores R2, and then independently replays
   frame 3, publishing SaveKey value 0x5A. Each source and relocated installed
   route proves this behavior with its own checkpoint and artifacts. Restore
   generation is compared only within B: changing its media to R2 advances
   B's prior generation once, and the producer's generation is not copied.
   The host owns checkpoint and save I/O, staging, commit decisions, exact
   reopen/readback, and acknowledgments. Restore and the controlled
   pre-rename failure preserve the selected R3 bytes and acknowledgment; an
   acknowledgment changes only after the host explicitly commits and verifies
   the restored payload. The version-2 snapshot header includes a SHA-256
   digest over its metadata with the digest field zeroed; it detects metadata
   corruption but is not authentication. This route is local macOS arm64
   evidence for the exact linked builds and content. It establishes no crash,
   abrupt-exit, fsync, power-loss,
   post-rename uncertainty, stable API/ABI/native state format, or cross-build
   portability guarantee. The API 7 selector and default-off installation
   remain unchanged.

   For the Nesturbator exceptions above, discover capability using the
   profile's documented selector, including NULL where the profile specifies
   it. For Muhtari API 8, query with profile muhtari-ntsc-v2 and the explicit
   muhtari-ntsc-battery-diagnostic configuration; the NULL selector returns
   LF_UNSUPPORTED. Snapshot operations on unloaded instances return
   LF_INVALID_ARGUMENT. This does not claim general portability, crash or
   power-loss durability, a stable shared format, or authentication. */
lf_status lf_get_snapshot_size(lf_instance *instance,
                               size_t *required_bytes);
/* The full destination capacity must be disjoint from the instance and other
   live API arguments. A short capacity returns LF_BUFFER_TOO_SMALL without
   writing the destination or changing the machine. */
lf_status lf_capture_snapshot(lf_instance *instance, uint8_t *destination,
                              size_t capacity_bytes);
/* The source span must remain readable for the call and disjoint from the
   instance. A rejected restore leaves the active machine, adapter
   continuation, and profile-defined media state unchanged. Restore does not
   change host-managed save files or acknowledgments. */
lf_status lf_restore_snapshot(lf_instance *instance, const uint8_t *source,
                              size_t extent_bytes);
/* The host owns and serializes the instance handle: LC-LIFE-01. */
lf_status lf_create(const char *profile_id, const lf_create_options *options,
                    lf_instance **out);
lf_status lf_destroy(lf_instance **owned);
/* Pending logical input and guest-time sampling: LC-INPUT-01, LC-TIME-01. */
lf_status lf_set_input(lf_instance *instance, const lf_input *input);
/* Loads content into the selected profile. The input byte span is borrowed
   only for this call; successful implementations own any retained copy.
   Load state effects and input ownership: LC-LOAD-01, LC-OWN-01. */
lf_status lf_load(lf_instance *instance, const lf_load_request *request,
                  lf_load_result *out);
/* Guest work, output ownership, and profile bounds: LC-TIME-01, LC-OWN-01,
   LC-LIMIT-01. */
lf_status lf_advance(lf_instance *instance, const lf_run_request *request,
                     lf_run_result *out);
/* Copies the exact loaded persistent-media span into caller-owned storage.
   The copy is independent of later calls. The media identity describes the
   media kind/slot; associate the bytes with loaded content and configuration
   in the host. `guest_generation` is profile-defined guest media change
   information, including any snapshot-restore effect specified by that
   profile; it is not a host revision or durability acknowledgment. The full
   destination capacity span must be disjoint from `out` and instance storage;
   overlap is invalid caller use and runtime detection is not promised. Calls
   on one instance must be serialized. LC-OWN-01, LC-HOST-01. */
lf_status lf_copy_media(lf_instance *instance, uint8_t *destination,
                        size_t capacity_bytes, lf_media_info *out);
/* Imports caller-owned bytes into the matching loaded media span. The source
   must remain readable for the call. Import is allowed after a successful
   load and before the first positive guest advance; it does not count as a
   guest write. Calls on one instance must be serialized. LC-OWN-01,
   LC-HOST-01. */
lf_status lf_import_media(lf_instance *instance, const char *identity,
                          const uint8_t *source, size_t extent_bytes);

#ifdef __cplusplus
}
#endif

#endif
