"""Opt-in update gate. No package operations: hand off to Omarchy unchanged."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import subprocess
import sys
import tempfile
import time

PLUGIN_ID = "p134c0d3.omapreflight"
IPC_LIMIT = 512 * 1024
SCAN_TIMEOUT = 130
STATUSES = {"pass", "warn", "fail", "unknown", "skipped"}
MISSING = object()


class GateError(Exception):
    pass


def clean(value):
    """Command output is text, never terminal control sequences."""
    return "".join(c if c.isprintable() else " " for c in str(value))


def state_dir():
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    if not base.is_absolute():
        raise GateError("XDG_STATE_HOME must be an absolute path.")
    return base / "omapreflight"


def read_json(path, limit=8192):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return MISSING
    with os.fdopen(fd, "rb") as file:
        metadata = os.fstat(file.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
            raise GateError("Refused non-regular or oversized state file: " + str(path))
        data = file.read(limit + 1)
        if len(data) > limit:
            raise GateError("State file exceeds its read limit.")
    try:
        return json.loads(data)
    except (ValueError, UnicodeError) as error:
        raise GateError("Could not parse " + str(path)) from error


def atomic_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    data = (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode()
    if len(data) > IPC_LIMIT:
        raise GateError("Update state exceeds its write limit.")
    fd, temporary = tempfile.mkstemp(prefix=".update-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def enabled(directory):
    settings = read_json(directory / "update-settings.json")
    if settings is MISSING:
        return False
    if (not isinstance(settings, dict) or settings.get("schemaVersion") != 1
            or type(settings.get("enabled")) is not bool):
        raise GateError("Unrecognized update settings; refusing to bypass preflight.")
    return settings["enabled"]


def bounded_command(argv, timeout=5):
    """Drain both pipes with a total byte ceiling and a wall-clock deadline."""
    deadline = time.monotonic() + timeout
    output = {"stdout": bytearray(), "stderr": bytearray()}
    with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, "stdout")
                selector.register(process.stderr, selectors.EVENT_READ, "stderr")
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise GateError("Omarchy IPC timed out.")
                    for key, _ in selector.select(remaining):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        output[key.data].extend(chunk)
                        if sum(map(len, output.values())) > IPC_LIMIT:
                            raise GateError("Omarchy IPC exceeded its output limit.")
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
        except BaseException:
            process.kill()
            process.wait()
            raise
    if process.returncode:
        raise GateError("OmaPreflight service is unavailable. Enable the plugin in Omarchy, "
                        "or turn auto-run off to use the ordinary updater.")
    return output["stdout"].decode("utf-8", errors="strict").strip()


def ipc(method, *args):
    return bounded_command(["omarchy-shell", PLUGIN_ID, method, *args])


def json_response(text):
    try:
        value = json.loads(text)
    except (ValueError, UnicodeError) as error:
        raise GateError("The preflight service returned malformed data.") from error
    if not isinstance(value, dict):
        raise GateError("The preflight service returned an unexpected response.")
    return value


def validate_snapshot(snapshot, scan_id):
    if (snapshot.get("ok") is not True or snapshot.get("schemaVersion") != 1
            or snapshot.get("scanId") != scan_id or not snapshot.get("completedAt")):
        raise GateError("Could not obtain the completed scan; update stopped.")
    rows = snapshot.get("results")
    if (not isinstance(rows, list) or not rows
            or type(snapshot.get("checkCount")) is not int or snapshot["checkCount"] != len(rows)):
        raise GateError("The completed checklist is empty.")
    ids = set()
    for row in rows:
        if (not isinstance(row, dict) or not isinstance(row.get("id"), str)
                or not row["id"] or row["id"] in ids or row.get("status") not in STATUSES):
            raise GateError("The completed checklist contains invalid results.")
        ids.add(row["id"])
    if snapshot.get("readiness") not in {"ready", "review", "not_recommended", "unknown"}:
        raise GateError("Unrecognized readiness; update stopped.")
    baseline = snapshot.get("baseline")
    if not isinstance(baseline, dict) or baseline.get("schemaVersion") != 1:
        raise GateError("The completed scan has no usable baseline.")
    return snapshot


def scan(call=ipc, sleep=time.sleep, monotonic=time.monotonic, timeout=SCAN_TIMEOUT):
    print("OmaPreflight: checking the current system before the update…", flush=True)
    scan_id = call("run")
    if not re.fullmatch(r"scan-[0-9]+", scan_id):
        raise GateError("Cannot start preflight (" + clean(scan_id) + "). No update was started.")
    deadline = monotonic() + timeout
    try:
        while monotonic() < deadline:
            status = json_response(call("status"))
            if status.get("scanId") != scan_id:
                raise GateError("The preflight scan was replaced or the shell restarted.")
            if status.get("scanRunning") is False:
                if status.get("lastCompletedScanId") != scan_id:
                    raise GateError("Preflight was cancelled or incomplete; update stopped.")
                return validate_snapshot(json_response(call("updateSnapshot", scan_id)), scan_id)
            if status.get("scanRunning") is not True:
                raise GateError("The preflight service returned an invalid scan state.")
            sleep(0.25)
        raise GateError("Preflight exceeded its time budget; update stopped.")
    except BaseException:
        # Only cancel the scan this invocation owns, never another user's scan.
        try:
            current = json_response(call("status"))
            if current.get("scanId") == scan_id and current.get("scanRunning") is True:
                call("cancelScan", scan_id)
        except (GateError, OSError, ValueError):
            pass
        raise


def print_checklist(snapshot):
    print("\nOmaPreflight checklist\n")
    for row in snapshot["results"]:
        qualifier = " (informational)" if row.get("material") is False else ""
        print(f"[{row['status'].upper():7}] {clean(row.get('title') or row['id'])}{qualifier}")
        print("          " + clean(row.get("summary", "")))
        if row["status"] in {"warn", "fail", "unknown", "skipped"}:
            for detail in row.get("details", []) if isinstance(row.get("details"), list) else []:
                print("          " + clean(detail))
            if row.get("remediation"):
                print("          Next: " + clean(row["remediation"]))
    print("\nReadiness: " + snapshot["readiness"].upper())
    print("These checks describe the current system; future package compatibility is not verified.", flush=True)


def may_continue(snapshot, unattended, interactive, ask=input):
    rows = snapshot["results"]
    # Independent guards protect against an inconsistent READY payload.
    if any(r["status"] == "fail" and r.get("severity") == "blocker" for r in rows):
        return False
    readiness = snapshot["readiness"]
    if readiness in {"unknown", "not_recommended"}:
        return False
    review = readiness == "review" or any(
        r["status"] == "fail" or (r["status"] in {"warn", "unknown"} and r.get("material") is not False)
        for r in rows)
    if not review:
        return True
    if unattended or not interactive:
        return False
    try:
        return ask("\nReview the findings above. Continue with the update? [y/N] ").strip().lower() in {"y", "yes"}
    except EOFError:
        return False


def acquire_update_lock():
    """Use the installed updater's lock contract, including its inherited FD."""
    directory = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
    if not directory.is_absolute():
        raise GateError("XDG_RUNTIME_DIR must be an absolute path.")
    fd = os.open(directory / "omarchy-update.lock",
                 os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise GateError("Refused non-regular update lock.")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.set_inheritable(fd, True)
        os.environ["OMARCHY_UPDATE_LOCK_FD"] = str(fd)
        return fd
    except BaseException:
        os.close(fd)
        raise


def gate(directory, unattended=False):
    snapshot = scan()
    print_checklist(snapshot)
    if not may_continue(snapshot, unattended, sys.stdin.isatty()):
        raise GateError("Preflight did not approve continuation. No update was started.")
    # Separate from the user's manually recorded baseline. Persist before any
    # update can restart the shell; this is evidence for a future postflight.
    atomic_json(directory / "pre-update.json", snapshot)
    print("\nPreflight accepted. Checklist and baseline saved.", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Optional OmaPreflight gate for the ordinary Omarchy updater.")
    commands = parser.add_subparsers(dest="command", required=True)
    auto = commands.add_parser("auto-run", help="Enable, disable, or inspect pre-update scanning")
    auto.add_argument("mode", choices=["enable", "disable", "status"])
    update = commands.add_parser("update", help="Run the optional checklist, then Omarchy update")
    update.add_argument("-y", action="store_true", help="Unattended: REVIEW stops instead of prompting")
    check = commands.add_parser("pre-update", help="Run the gate if enabled, without launching an update")
    check.add_argument("-y", action="store_true", help="Never prompt to override REVIEW")
    args = parser.parse_args(argv)
    lock = None
    try:
        directory = state_dir()
        if args.command == "auto-run":
            if args.mode != "status":
                atomic_json(directory / "update-settings.json", {
                    "schemaVersion": 1, "enabled": args.mode == "enable"
                })
            print("Pre-update auto-run: " + ("enabled" if enabled(directory) else "disabled"))
            print("Applies to `omapreflight update`; ordinary `omarchy update` is unchanged.")
            return 0
        active = enabled(directory)
        if active:
            lock = acquire_update_lock()
            gate(directory, args.y or os.environ.get("OMARCHY_UPDATE_UNATTENDED") == "1")
        if args.command == "pre-update":
            if not active:
                print("Pre-update auto-run is disabled; skipping checklist.")
            return 0
        updater = shutil.which("omarchy")
        if not updater:
            raise GateError("The Omarchy CLI is not available.")
        print("Continuing with Omarchy update…", flush=True)
        # Updater owns its own timeouts, interactivity, logging and privilege
        # handling. Never time-limit or kill it as though it were a diagnostic.
        os.execv(updater, [updater, "update"] + (["-y"] if args.y else []))
    except BlockingIOError:
        print("An Omarchy update is already running; preflight stopped.", file=sys.stderr)
        return 1
    except (GateError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print("OmaPreflight: " + clean(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nPreflight cancelled. No update was started.", file=sys.stderr)
        return 130
    finally:
        if lock is not None:
            os.close(lock)
