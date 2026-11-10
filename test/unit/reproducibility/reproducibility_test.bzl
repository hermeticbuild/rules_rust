"""Compare binaries built in configurations differing only by an unused build setting."""

_CONFIGURATION = str(Label("//test/unit/reproducibility:configuration"))

def _first_impl(_settings, _attr):
    return {_CONFIGURATION: "first"}

def _second_impl(_settings, _attr):
    return {_CONFIGURATION: "second"}

_first = transition(
    implementation = _first_impl,
    inputs = [],
    outputs = [_CONFIGURATION],
)

_second = transition(
    implementation = _second_impl,
    inputs = [],
    outputs = [_CONFIGURATION],
)

def _reproducibility_test_impl(ctx):
    first = ctx.attr.first[0][DefaultInfo].files_to_run.executable
    second = ctx.attr.second[0][DefaultInfo].files_to_run.executable
    if first.root.path == second.root.path:
        fail("The fixture must exercise different configuration output roots")
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        executable,
        """#!/usr/bin/env bash
set -euo pipefail
first="$TEST_SRCDIR/$TEST_WORKSPACE/first"
second="$TEST_SRCDIR/$TEST_WORKSPACE/second"
cmp "$first" "$second"
first_output="$("$first")"
second_output="$("$second")"
test "$first_output" = "$second_output"
case "$first_output" in
  *bazel-out*) echo "Configuration-dependent source path: $first_output"; exit 1 ;;
esac
""",
        is_executable = True,
    )
    return [DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(symlinks = {"first": first, "second": second}),
    )]

reproducibility_test = rule(
    implementation = _reproducibility_test_impl,
    test = True,
    attrs = {
        "first": attr.label(mandatory = True, cfg = _first),
        "second": attr.label(mandatory = True, cfg = _second),
        "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
    },
)
