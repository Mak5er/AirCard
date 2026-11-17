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
