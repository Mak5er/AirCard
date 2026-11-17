# Card write diagnostics

This standalone macOS tool diagnoses the old AirTraffic link-relocation path.
It does **not** flash a Wallet card or demonstrate that a patched iOS version
supports artwork changes. The normal AirCard GUI and flash commands are unchanged.

## Experiment

The tool uses an explicit paired iPhone and one random run token. It snapshots
the tracked Books state and stages the existing archive layout, whose contained
relative link names `/var/tmp`. It submits exactly two assets:

1. Move the staged link to a new random node in Media.
2. Move random control text directly to another random node in Media.

No payload is sent through the relocated link. No canary is written to
`/var/tmp`, and no Wallet files are read or modified. The control readback and
post-move link type distinguish an observed effect from merely sending requests.

| Outcome | Meaning |
| --- | --- |
| `link_materialized` | The source was a symbolic link, the destination became a directory, and the independent control bytes matched. This is consistent with the behavior reported in [AirLift #11](https://github.com/0xjohnnydev/airlift/issues/11). |
| `link_preserved` | The relocated object remains a symbolic link and the control bytes matched. External writes and existing Wallet artwork replacement remain untested. |
| `phase_failed` | A specific preflight, snapshot, staging, sync, or observation call failed. Inspect that phase's error; do not automatically attribute it to an iOS patch. |
| `inconclusive` | The objects or control bytes did not establish either link result within the bounded observation period. |

Cleanup and Books restoration have separate `verified`, `failed`, or `unknown`
states. A successful observation does not imply successful cleanup.

## Build and run

Use the source checkout's freshly built helpers, rather than binaries from an
installed app. No additional Python packages are needed.

```sh
make build/device_helper build/airtraffic_host
./build/device_helper list
python3 tools/card-write-diagnostics/run.py run --device YOUR_DEVICE_IDENTIFIER
```

The final JSON includes the private `run_dir` and an observation report.
Exit code 0 means the diagnostic completed with a link observation and verified
cleanup; it does not mean card flashing is supported. Exit code 1 means the
diagnostic did not establish a link result; exit code 2 requires recovery.

Each run lives under the Git-ignored `.tmp/card-write-diagnostics/` directory.
It retains a private journal, input hashes, Books snapshot, and helper/source
hashes. A local device lock prevents concurrent runs in that checkout. An
unfinished run blocks another experiment for the same device. Do not run another
Books sync or AirCard operation while diagnosing or recovering.

## Recovery

```sh
python3 tools/card-write-diagnostics/run.py recover \
  --device YOUR_DEVICE_IDENTIFIER --run-dir "/absolute/path/from/run_dir"
```

Recovery verifies the original inputs and device, never stages another archive,
and never resends the assets. If a sync was interrupted, it first checks whether
both planned effects and the control bytes can now be verified. If not, it
retains `recovery_required` and does not overwrite Books while sync state is
unknown. An interrupted staging call likewise remains unresolved; this command
cannot establish that the device-side unpacker is idle.

The native cleanup command only removes the run's known Media objects. It does
not traverse the relocated link, or recursively erase an unexpected directory.
It restores Books only when the current state matches the original snapshot or
the known change to this run's `Books/Sync/Books.plist`. An unexplained change
produces a recovery conflict and leaves the snapshot in place.
Even when Books restoration conflicts, known Media objects can be cleaned
independently. This can produce `media_cleanup=verified` with
`books_restore=unknown` and `recovery_required=true`; it does not mean the full
original Books state was restored. Recovery records its own tool fingerprints
separately when a fixed helper is used after the original experiment.

### Roll back only the diagnostic's own Books input

After reviewing a Books conflict, an explicit, narrower rollback is available:

```sh
python3 tools/card-write-diagnostics/run.py restore-owned-books \
  --device YOUR_DEVICE_IDENTIFIER --run-dir "/absolute/path/from/run_dir"
```

This requires verified sync effects, verified Media cleanup, and unchanged local
recovery inputs. The native command only handles `Books/Sync/Books.plist` when
the original snapshot says it was absent and its current bytes still exactly
match the two assets generated for this run token. It saves and verifies a
private backup, repeats the state checks, removes that one input, and verifies
its absence. An originally existing input is unsupported by this narrow path.
It never modifies the Books index, database, sidecars, other files, or directories.

`owned_books_restore` and `other_books_unchanged` record this limited rollback.
Even when both are verified, full `books_restore` remains unknown and
`recovery_required` remains true: preserving unexplained metadata is not a
restoration of the complete original snapshot. AFC does not provide a verified
atomic compare-and-delete operation; repeated checks reduce but cannot eliminate
the race with other device-side activity. Changed or unverifiable state stops
the operation without an automatic retry.

`report.json` is the shareable summary: model, iOS build, tool hashes, stage
statuses, observation, and recovery state. The CLI additionally prints the local
run directory. Do not publish `state.json`, `events.jsonl`, Books snapshots, or
device identifiers. No card identifiers or full device logs are collected.

## Offline verification

```sh
python3 -m unittest discover -s tests -p 'test_card_write_diagnostics*.py'
python3 -m unittest discover -s tests -p 'test_card_flash.py'
```

The native tests use fake AFC file effects and require macOS/Xcode command-line
tools. The Python tests inject link changes, control mismatches, service errors,
timeouts, interruption, cleanup conflicts, and recovery. They do not connect to a
phone, and passing them is not evidence of real-device link relocation.

Initial validation on 2026-11-17: offline tests and helper builds passed. A
read-only device enumeration returned no devices; the Media experiment was not
started. No patched-iOS real-device success is claimed.

### Real-device follow-up, 2026-11-17

On iPhone 13 (`iPhone14,5`), iOS 27.2 (`24B119`), the staged object was
`S_IFLNK`, the relocated destination was `S_IFDIR`, and the independent Media
control text matched exactly: `link_materialized`. This supports the reported
patch behavior on this device; it does not establish that every possible file
access method is blocked.

The first preflight revealed that the native AFC call returned raw status `8`
for nonexistent objects. A read-only root-versus-random-missing control confirmed
`0` versus `8`; the helper now accepts both raw `8` and its encoded form
`0xe8004008`, while permission and connection errors remain errors.

Media cleanup was verified. During sync, previously absent tracked Books index
and database files appeared. Their origin and full restoration were not proven,
so the recovery guard preserved all Books content and the original snapshot.
`books_restore` remains `unknown` and `recovery_required` remains `true`; no
further experiments were attempted. No Wallet resources or external payloads
were written. The [sanitized report](reports/2026-11-17-iphone13-ios27.2.json)
retains separate experiment and recovery tool hashes.

After explicit review of this conflict, the run's 213-byte sync input still
matched exactly and the original snapshot recorded it as absent. The narrow
`restore-owned-books` operation saved and verified a private backup, removed
only that input, and verified its absence. All other tracked Books bytes and
directory presence/type matched before and after the operation:
`owned_books_restore=verified`, `other_books_unchanged=true`. The newly appeared
index/database files were left in place, so full restoration remains unverified
and the experiment blocker remains active. Offline verification now includes
25 diagnostic checks and 7 existing card-flash checks.
