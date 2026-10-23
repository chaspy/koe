#!/usr/bin/env python3
"""Opt-in launchd integration: temporary dummy apps and unique test jobs only.
Run manually: python3 macos/Tests/auto-restart/test_integration.py
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
SOURCES = HERE.parents[1] / "Sources" / "Koe"


def wait_for(predicate, seconds=50):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError("fixture timed out")


def launchctl(*args):
    return subprocess.run(["/bin/launchctl", *args], capture_output=True, timeout=15)


with tempfile.TemporaryDirectory(prefix="koe-restart-test-") as build:
    build = Path(build)
    shutil.copy(HERE / "fixture.swift", build / "main.swift")
    subprocess.run(["nice", "-n", "15", "swiftc", str(SOURCES / "AutoRestart.swift"),
                    str(SOURCES / "ServerLifecycle.swift"), str(build / "main.swift"),
                    "-o", str(build / "Dummy")], check=True)
    for mode in ("normal", "save-failure"):
        with tempfile.TemporaryDirectory(prefix="koe-restart-test-") as directory:
            root = Path(directory)
            label = "io.github.chaspy.koe.restart.test." + uuid.uuid4().hex
            target = f"gui/{os.getuid()}/{label}"
            assert label != "io.github.chaspy.koe.restart"
            assert launchctl("print", target).returncode != 0
            (root / "label").write_text(label)
            bundle = root / "Dummy.app"
            executable = bundle / "Contents/MacOS/Dummy"
            executable.parent.mkdir(parents=True)
            shutil.copy(build / "Dummy", executable)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": label + ".app", "CFBundleExecutable": "Dummy",
                "CFBundleName": "Restart Test", "CFBundlePackageType": "APPL", "LSUIElement": True,
            }))
            subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True,
                           capture_output=True)
            session = root / "session.json"
            session.write_text(json.dumps({"identity": {"pid": 1, "path": "/invalid",
                "seconds": 0, "microseconds": 0}, "quitRequested": False}))
            plist = root / "agent.plist"
            plist.write_bytes(plistlib.dumps({"Label": label,
                "ProgramArguments": [str(executable), "--auto-restart-agent", str(bundle), str(plist), str(session)],
                "KeepAlive": {"SuccessfulExit": False}, "RunAtLoad": True,
                "ThrottleInterval": 30, "LimitLoadToSessionType": "Aqua", "ProcessType": "Background"}))
            def count():
                return int((root / "count").read_text()) if (root / "count").exists() else 0
            try:
                assert launchctl("bootstrap", f"gui/{os.getuid()}", str(plist)).returncode == 0
                wait_for(lambda: count() == 2)
                print(f"{mode}: abnormal exit restarted (starts=2)", flush=True)
                (root / "quit").write_text(mode)
                wait_for(lambda: (root / "finished").exists(), 10)
                time.sleep(35)  # Beyond launchd's real 30-second throttle.
                assert count() == 2
                if mode == "normal":
                    assert json.loads(session.read_text())["quitRequested"]
                    status = launchctl("print", target)
                    assert status.returncode == 0 and b"last exit code = 0" in status.stdout
                else:
                    assert not plist.exists()
                    assert launchctl("print", target).returncode != 0
                print(f"{mode}: explicit quit did not restart (starts=2)", flush=True)
            finally:
                # Disarm first, then allow any surviving dummy to exit gracefully.
                launchctl("bootout", target)
                plist.unlink(missing_ok=True)
                (root / "quit").write_text("normal")
                subprocess.run([str(executable), "--cleanup", str(root)], check=True, timeout=10)
                assert launchctl("print", target).returncode != 0
                print(f"{mode}: test job booted out and plist removed", flush=True)
print("launchd integration passed; temporary directories removed")
