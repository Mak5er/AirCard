#!/usr/bin/env python3
"""Diagnose link relocation using only this run's disposable Media objects."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from apply_card_skin import build_archive, build_books  # noqa: E402

POLL_SECONDS = 5


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command_json(command, timeout):
    """Bound the entire child lifetime, including blocked stdout reads."""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        except ProcessLookupError:
            process.wait()
        raise
    for line in reversed(stdout.splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return {**value, "exitCode": process.returncode}
    raise RuntimeError(f"{Path(command[0]).name}: no JSON result; {stderr[-2048:]}")


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


class Runner:
    def __init__(self, device, work_root=None, command_runner=None):
        if not device or "\x00" in device:
            raise ValueError("An explicit device identifier is required")
        self.device = device
        self.work_root = (Path(work_root) if work_root else ROOT / ".tmp/card-write-diagnostics").resolve()
        self.command_runner = command_runner or command_json
        self.helper = ROOT / "build/device_helper"
        self.host = ROOT / "build/airtraffic_host"
        self.state = {}
        self.directory = None

    @contextmanager
    def lock(self):
        self.work_root.mkdir(parents=True, exist_ok=True)
        path = self.work_root / (".device-" + digest(self.device.encode()) + ".lock")
        with path.open("a") as stream:
            os.chmod(path, 0o600)
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("Another diagnostic holds this device lock") from None
            yield

    def save(self):
        atomic_json(self.directory / "state.json", self.state)

    def event(self, phase, result=None):
        self.state["phase"] = phase
        if isinstance(result, dict):
            public = {key: result[key] for key in (
                "exitCode", "subscribeStatus", "targetObserved", "connectStatus", "validateStatus",
                "sessionStatus", "serviceStatus", "afcStatus", "targetGatePassed", "errorType") if key in result}
            operation = result.get("operation", {})
            public.update({key: operation[key] for key in (
                "zipServiceStatus", "zipMessageStatus", "zipResponseStatus", "archiveSent",
                "sourceObjectsPresent", "booksWritten", "snapshotVerified") if key in operation})
            if "objects" in operation:
                public["objects"] = {name: {key: obj[key] for key in ("state", "status", "kind") if key in obj}
                                     for name, obj in operation["objects"].items()}
            self.state.setdefault("stage_results", {}).setdefault(phase, {}).update(public)
        self.save()
        with (self.directory / "events.jsonl").open("a") as stream:
            os.chmod(stream.name, 0o600)
            json.dump({"phase": phase, "time": time.time(), "result": result}, stream)
            stream.write("\n")

    def native(self, command, *arguments):
        result = self.command_runner([str(self.helper), command, self.device,
                                      *map(str, arguments)], 60)
        self.event(self.state["phase"], result)
        return result

    def sync(self, identifiers, destinations):
        arguments = [v for pair in zip(identifiers, destinations) for v in pair]
        result = self.command_runner([str(self.host), self.device, *arguments], 120)
        self.event("sync", result)
        return result

    @staticmethod
    def require(result):
        if not (result.get("exitCode") == 0 and result.get("targetGatePassed")
                and result.get("operation", {}).get("ok")):
            raise RuntimeError("Device operation failed; see this run's private events.jsonl")
        return result["operation"]

    def status(self):
        operation = self.require(self.native("diagnostic-status", self.state["token"]))
        objects = operation.get("objects", {})
        for name in ("source", "stagedLink", "payload", "link", "control"):
            if objects.get(name, {}).get("state") not in ("present", "missing"):
                raise RuntimeError(f"Unverified object status: {name}")
        return objects

    def remember_inputs(self):
        files = [self.directory / name for name in ("expected.bin", "Books.plist", "payload.zip")]
        files.extend((self.directory / "snapshot").iterdir())
        self.state["input_hashes"] = {
            str(path.relative_to(self.directory)): digest(path.read_bytes())
            for path in files if path.is_file() and not path.is_symlink()
        }
        self.save()

    def verify_inputs(self):
        hashes = self.state.get("input_hashes", {})
        for required in ("expected.bin", "Books.plist", "payload.zip", "snapshot/manifest.plist"):
            if required not in hashes:
                raise ValueError("Incomplete recovery inputs")
        for name, expected in hashes.items():
            relative = Path(name)
            path = self.directory / relative
            if (relative.is_absolute() or ".." in relative.parts or path.is_symlink()
                    or not path.resolve().is_relative_to(self.directory.resolve())
                    or digest(path.read_bytes()) != expected):
                raise ValueError("Recovery inputs changed")

    def observe(self):
        deadline = time.monotonic() + POLL_SECONDS
        while True:
            objects = self.status()
            link, control = objects["link"], objects["control"]
            if (link.get("state") == "present" and link.get("kind") in ("S_IFDIR", "S_IFLNK")
                    and control.get("state") == "present" and control.get("kind") == "S_IFREG"):
                self.require(self.native("afc-read", self.state["control"],
                                         self.directory / "observed.bin"))
                matched = ((self.directory / "observed.bin").read_bytes()
                           == (self.directory / "expected.bin").read_bytes())
                self.state["control_bytes_match"] = matched
                self.state["link_kind"] = link["kind"]
                self.state["sync_completed_verified"] = matched
                self.save()
                if matched:
                    return "link_materialized" if link["kind"] == "S_IFDIR" else "link_preserved"
                return "inconclusive"
            if time.monotonic() >= deadline:
                return "inconclusive"
            time.sleep(0.25)

    def cleanup(self):
        if not self.state.get("stage_issued"):
            self.state.update(media_cleanup="not_needed", books_restore="not_needed",
                              recovery_required=False)
            return
        safe = (self.state.get("stage_result_known") and self.state.get("cleanup_authorized", True) and
                (not self.state.get("sync_issued") or self.state.get("sync_no_assets_sent")
                 or self.state.get("sync_completed_verified")))
        if not safe:
            self.state.update(media_cleanup="unknown", books_restore="unknown",
                              recovery_required=True)
            return
        self.event("cleanup")
        result = self.native("diagnostic-cleanup", self.state["token"],
                             self.directory / "snapshot", self.directory / "Books.plist")
        operation = result.get("operation", {})
        media = operation.get("mediaCleanup", "unknown")
        books = operation.get("booksRestore", "unknown")
        valid = (result.get("exitCode") == 0 and result.get("targetGatePassed")
                 and operation.get("ok"))
        if not valid and media == books == "verified":
            media = books = "unknown"
        self.state.update(media_cleanup=media, books_restore=books,
                          recovery_required=not (media == books == "verified"),
                          recovery_conflict=bool(operation.get("conflict")))

    def finish(self, outcome, failure_phase=None, error=None):
        self.state["outcome"] = outcome
        if error:
            self.state["error"] = type(error).__name__
            self.event(failure_phase or self.state["phase"],
                       {"errorType": type(error).__name__, "message": str(error).replace(self.device, "<device>")})
        try:
            self.cleanup()
        except (Exception, KeyboardInterrupt) as exc:
            self.state.update(media_cleanup="unknown", books_restore="unknown", recovery_required=True)
            self.event("cleanup", {"errorType": type(exc).__name__})
        self.state["failure_phase"] = failure_phase
        self.save()
        report = {key: self.state.get(key) for key in (
            "outcome", "failure_phase", "media_cleanup", "books_restore", "recovery_required",
            "recovery_conflict", "control_bytes_match", "link_kind", "device_info", "tools", "error",
            "stage_results")}
        report.update(phase=failure_phase or self.state["phase"], wallet_write_attempted=False,
                      external_payload_write_attempted=False)
        atomic_json(self.directory / "report.json", report)
        return {**report, "run_dir": str(self.directory)}

    def run(self):
        with self.lock():
            return self._run()

    def _run(self):
        self.work_root.mkdir(parents=True, exist_ok=True)
        # An interrupted run must be resolved before another test on this device.
        for path in self.work_root.glob("*/state.json"):
            previous = json.loads(path.read_text())
            if (previous.get("device_hash") == digest(self.device.encode())
                    and previous.get("stage_issued") and
                    previous.get("recovery_required", True)):
                raise ValueError(f"Recover the existing run first: {path.parent}")
        self.directory = self.work_root / secrets.token_hex(10)
        self.directory.mkdir(mode=0o700)
        token = self.directory.name
        self.state = {"version": 1, "token": token, "device_hash": digest(self.device.encode()),
                      "source": f"airlift-src-{token}", "link": f"airlift-link-{token}",
                      "control": f"airlift-recovered-{token}", "phase": "prepare",
                      "recovery_required": False, "control_bytes_match": None,
                      "stage_issued": False, "stage_result_known": False,
                      "sync_issued": False, "sync_result_known": False,
                      "sync_completed_verified": False, "sync_no_assets_sent": False}
        self.save()
        outcome, failed, error = "phase_failed", None, None
        try:
            tools = {}
            for path in (self.helper, self.host):
                tools[path.name] = digest(path.read_bytes()) if path.is_file() else "missing"
            tools["source_hashes"] = {str(path.relative_to(ROOT)): digest(path.read_bytes())
                                      for path in (Path(__file__), ROOT / "Sources/device_helper.m",
                                                   ROOT / "Sources/card_write_diagnostics.h") if path.is_file()}
            self.state["tools"] = tools
            if self.command_runner is command_json and "missing" in tools.values():
                raise RuntimeError("Build device_helper and airtraffic_host with make first")
            self.event("preflight")
            probe = self.native("probe")
            self.require(probe)
            self.state["device_info"] = {k: probe.get(k) for k in (
                "productType", "productVersion", "buildVersion")}
            if not str(probe.get("productType", "")).startswith("iPhone"):
                raise RuntimeError("The selected device is not a confirmed iPhone")
            objects = self.status()
            if any(objects[k]["state"] != "missing" for k in ("source", "link", "control")):
                raise RuntimeError("Disposable paths are not verified absent")
            payload = ("AirCard Media-only diagnostic " + secrets.token_hex(32) + "\n").encode()
            identifiers = [f"../../{self.state['source']}/p0/p1/p2/link",
                           f"../../{self.state['source']}/payload"]
            destinations = [self.state["link"], self.state["control"]]
            (self.directory / "expected.bin").write_bytes(payload)
            (self.directory / "Books.plist").write_bytes(build_books(identifiers))
            (self.directory / "payload.zip").write_bytes(build_archive("/var/tmp", payload))
            (self.directory / "snapshot").mkdir()
            self.event("snapshot")
            self.require(self.native("diagnostic-snapshot", self.directory / "snapshot"))
            self.remember_inputs()
            self.state["stage_issued"] = True
            self.state["recovery_required"] = True
            self.event("stage")
            staged = self.native("stage", self.state["source"], self.state["link"],
                                 self.state["control"], self.directory / "payload.zip",
                                 self.directory / "Books.plist", self.directory / "snapshot")
            self.state["stage_result_known"] = True
            self.state["cleanup_authorized"] = staged.get("operation", {}).get("cleanupAuthorized", True)
            self.save()
            self.require(staged)
            self.event("staged_status")
            objects = self.status()
            staged_link = objects["stagedLink"]
            if (staged_link.get("kind") != "S_IFLNK" or
                    staged_link.get("linkTarget") != "../../../var/tmp" or
                    objects["payload"].get("kind") != "S_IFREG"):
                raise RuntimeError("The staged link/payload did not match the diagnostic design")
            self.state["sync_issued"] = True
            self.event("sync")
            synced = self.sync(identifiers, destinations)
            self.state["sync_result_known"] = True
            # These existing host failures occur before any AssetCompleted call.
            self.state["sync_no_assets_sent"] = (
                synced.get("exitCode") in (2, 3, 4, 5, 64) and not synced.get("ok"))
            self.save()
            if synced.get("exitCode") != 0 or not synced.get("ok"):
                raise RuntimeError("AirTraffic did not complete; see private stage results")
            self.event("observe")
            outcome = self.observe()
        except (Exception, KeyboardInterrupt) as exc:
            failed, error = self.state["phase"], exc
        return self.finish(outcome, failed, error)

    def recover(self, run_dir):
        with self.lock():
            return self._recover(run_dir)

    def _recover(self, run_dir):
        self.directory = Path(run_dir).resolve()
        self.state = json.loads((self.directory / "state.json").read_text())
        if (self.state.get("version") != 1 or
                not re.fullmatch(r"[0-9a-f]{20}", self.state.get("token", "")) or
                self.state.get("device_hash") != digest(self.device.encode())):
            raise ValueError("Recovery requires the original run and the same explicit device")
        token = self.state["token"]
        if any(self.state.get(key) != prefix + token for key, prefix in (
            ("source", "airlift-src-"), ("link", "airlift-link-"), ("control", "airlift-recovered-"))):
            raise ValueError("Invalid generated recovery paths")
        if (not self.state.get("recovery_required", True) and
                self.state.get("media_cleanup") in ("verified", "not_needed") and
                self.state.get("books_restore") in ("verified", "not_needed")):
            return {**json.loads((self.directory / "report.json").read_text()),
                    "run_dir": str(self.directory)}
        if not self.state.get("stage_issued"):
            return self.finish(self.state.get("outcome", "phase_failed"))
        self.verify_inputs()
        error, failed = None, None
        try:
            self.event("recovery_status")
            self.require(self.native("probe"))
            if (self.state.get("stage_result_known") and self.state.get("sync_issued") and
                    not self.state.get("sync_completed_verified") and
                    not self.state.get("sync_no_assets_sent")):
                self.state["outcome"] = self.observe()
            # A killed staging call may still have server-side work pending.
            # Keep it unknown rather than deleting objects while unpacking.
        except (Exception, KeyboardInterrupt) as exc:
            error, failed = exc, self.state["phase"]
        return self.finish(self.state.get("outcome", "inconclusive"), failed, error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="mode", required=True)
    for mode in ("run", "recover"):
        command = subcommands.add_parser(mode)
        command.add_argument("--device", required=True)
        if mode == "recover":
            command.add_argument("--run-dir", required=True)
    args = parser.parse_args()
    runner = Runner(args.device)
    try:
        report = runner.run() if args.mode == "run" else runner.recover(args.run_dir)
    except (Exception, KeyboardInterrupt) as exc:
        print(json.dumps({"outcome": "phase_failed", "error": type(exc).__name__,
                          "message": str(exc).replace(args.device, "<device>")}))
        return 1
    print(json.dumps(report, indent=2))
    return 2 if report["recovery_required"] else int(report["outcome"] in ("phase_failed", "inconclusive"))


if __name__ == "__main__":
    raise SystemExit(main())
