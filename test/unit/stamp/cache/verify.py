#!/usr/bin/env python3
"""Exercise stamp cache invalidation with real Bazel actions and generated env files.

Run from the workspace root: python3 test/unit/stamp/cache/verify.py
The isolated status command never changes tracked source files.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

PACKAGE = "test/unit/stamp/cache"
TARGETS = [
    "auto_unused",
    "auto_used",
    "auto_generated",
    "auto_build_script",
    "auto_overridden",
    "auto_lib",
    "auto_lib_consumer",
    "auto_from_lib",
    "auto_volatile",
    "explicit_unused",
    "explicit_used",
    "disabled",
]
AUTOMATIC = {
    "auto_unused", "auto_used", "auto_generated", "auto_build_script",
    "auto_overridden", "auto_lib", "auto_volatile",
}
CONSUMERS = {
    "auto_used", "auto_generated", "auto_build_script", "auto_lib",
    "auto_lib_consumer", "auto_from_lib",
}
EXPLICIT = {"explicit_unused", "explicit_used"}



def records(path):
    # Bazel versions write either a JSON array or consecutive JSON objects.
    data = path.read_text()
    decoder = json.JSONDecoder()
    while data.strip():
        data = data.lstrip()
        value, end = decoder.raw_decode(data)
        yield from value if isinstance(value, list) else [value]
        data = data[end:]


def verify(bazel, metadata=False):
    temporary = tempfile.mkdtemp(prefix="rust-stamp-env-")
    temporary = Path(temporary)
    print(f"Logs: {temporary}", flush=True)
    status = temporary / "status.txt"
    command = temporary / "status.sh"
    command.write_text(f'#!/bin/sh\ncat "{status}"\n')
    command.chmod(0o755)

    def build(name, used, unrelated, volatile, stamping=True):
        status.write_text(
            f"STABLE_RUST_STAMP_TEST {used}\n"
            f"STABLE_RUST_STAMP_UNRELATED {unrelated}\n"
            f"RUST_STAMP_VOLATILE {volatile}\n"
        )
        execution_log = temporary / f"{name}.json"
        log = temporary / f"{name}.log"
        targets = ["auto_lib", "auto_lib_consumer"] if metadata else TARGETS
        invocation = [bazel, "build", *[f"//{PACKAGE}:{target}" for target in targets],
                      f"--workspace_status_command={command}",
                      f"--execution_log_json_file={execution_log}",
                      "--stamp" if stamping else "--nostamp",
                      "--noshow_progress"]
        if metadata:
            invocation.extend(["--@rules_rust//rust/settings:always_enable_metadata_output_groups",
                               "--output_groups=+build_metadata"])
        with log.open("w") as output:
            result = subprocess.run(invocation, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise AssertionError(log.read_text())
        actions = list(records(execution_log))
        if name == "initial" and metadata:
            assert any(action.get("mnemonic") == "RustcMetadata" and
                       action.get("targetLabel", "").endswith(":auto_lib")
                       for action in actions), "fixture must exercise metadata compilation"
        compiled = {
            action.get("targetLabel", "").rsplit(":", 1)[-1]
            for action in actions
            if action.get("mnemonic", "").startswith("Rustc")
            and PACKAGE in action.get("targetLabel", "")
        }
        resolved = {
            action.get("targetLabel", "").rsplit(":", 1)[-1]
            for action in actions
            if action.get("mnemonic") == "RustStampEnv"
            and PACKAGE in action.get("targetLabel", "")
        }
        print(f"{name}: Rustc={sorted(compiled)}, RustStampEnv={sorted(resolved)}", flush=True)
        return compiled, resolved

    def output(target, expected):
        value = subprocess.check_output([str(Path("bazel-bin") / PACKAGE / target)], text=True).strip()
        assert value == expected, (target, value, expected)

    if metadata:
        # Use a unique value so this also verifies metadata execution on reruns.
        first = temporary.name + "-A"
        second = temporary.name + "-B"
        build("initial", first, "one", "v1")
        compiled, _ = build("unused_stamp_changed", first, "two", "v1")
        assert not compiled, compiled
        compiled, _ = build("consumed_stamp_changed", second, "two", "v1")
        assert {"auto_lib", "auto_lib_consumer"} <= compiled, compiled
        print("PASS: metadata cache invalidation", flush=True)
        return

    build("initial", "A", "one", "v1")
    for target in CONSUMERS - {"auto_lib", "auto_lib_consumer"} | {"explicit_used"}:
        output(target, "A")
    output("disabled", "{STABLE_RUST_STAMP_TEST}")
    output("auto_volatile", "v1")
    output("auto_overridden", "constant")

    compiled, resolved = build("unused_stamp_changed", "A", "two", "v1")
    assert not compiled & (AUTOMATIC | {"auto_from_lib", "disabled"}), compiled
    assert EXPLICIT <= compiled, compiled
    assert AUTOMATIC <= resolved, resolved

    compiled, _ = build("consumed_stamp_changed", "B", "two", "v1")
    assert CONSUMERS | EXPLICIT <= compiled, compiled
    assert not compiled & {"auto_unused", "auto_volatile", "auto_overridden", "disabled"}, compiled
    for target in CONSUMERS - {"auto_lib", "auto_lib_consumer"} | {"explicit_used"}:
        output(target, "B")

    compiled, resolved = build("volatile_only_changed", "B", "two", "v2")
    assert not compiled, compiled
    assert not resolved, resolved
    output("auto_volatile", "v1")  # Preserve Bazel's best-effort volatile semantics.

    compiled, _ = build("stable_change_refreshes_volatile", "B", "three", "v2")
    assert {"auto_volatile"} | EXPLICIT <= compiled, compiled
    assert not compiled & (CONSUMERS | {"auto_unused", "auto_overridden", "disabled"}), compiled
    output("auto_volatile", "v2")

    compiled, resolved = build("nostamp", "B", "three", "v2", stamping=False)
    assert not resolved, resolved
    for target in CONSUMERS - {"auto_lib", "auto_lib_consumer"}:
        output(target, "{STABLE_RUST_STAMP_TEST}")
    output("explicit_used", "B")
    output("disabled", "{STABLE_RUST_STAMP_TEST}")
    print("PASS: automatic, explicit, disabled, generated, Cargo and volatile stamping", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", default="bazel")
    bazel = parser.parse_args().bazel
    verify(bazel)
    verify(bazel, metadata=True)
