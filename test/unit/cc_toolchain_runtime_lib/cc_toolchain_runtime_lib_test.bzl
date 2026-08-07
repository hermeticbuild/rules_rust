"""
Tests for handling of cc_toolchain's static_runtime_lib/dynamic_runtime_lib.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "feature", "flag_group", "flag_set")
load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")
load("//rust:defs.bzl", "rust_binary", "rust_shared_library", "rust_static_library")

def _test_cc_config_impl(ctx):
    config_info = cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "test-cc-toolchain",
        host_system_name = "unknown",
        target_system_name = "unknown",
        target_cpu = "unknown",
        target_libc = "unknown",
        compiler = "unknown",
        abi_version = "unknown",
        abi_libc_version = "unknown",
        features = [
            feature(name = "static_link_cpp_runtimes", enabled = True),
            feature(
                name = "test_linker_driver_args",
                enabled = True,
                flag_sets = [
                    flag_set(
                        actions = [ACTION_NAMES.cpp_link_executable],
                        flag_groups = [
                            flag_group(flags = [
                                "-unwindlib=none",
                                "--unwindlib=none",
                                "-Wl,--retained-link-arg",
                            ]),
                        ],
                    ),
                ],
            ),
        ],
    )
    return config_info

test_cc_config = rule(
    implementation = _test_cc_config_impl,
    provides = [CcToolchainConfigInfo],
)

def _with_extra_toolchain_transition_impl(_settings, attr):
    return {"//command_line_option:extra_toolchains": [attr.extra_toolchain]}

with_extra_toolchain_transition = transition(
    implementation = _with_extra_toolchain_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:extra_toolchains"],
)

DepActionsInfo = provider(
    "Contains information about dependencies actions.",
    fields = {
        "actions": "List[Action]",
        "runfiles": "List[File]",
    },
)

def _with_extra_toolchain_impl(ctx):
    return [
        DepActionsInfo(
            actions = ctx.attr.target[0].actions,
            runfiles = ctx.attr.target[0][DefaultInfo].default_runfiles.files.to_list(),
        ),
    ]

with_extra_toolchain = rule(
    implementation = _with_extra_toolchain_impl,
    attrs = {
        "extra_toolchain": attr.label(),
        "target": attr.label(cfg = with_extra_toolchain_transition),
    },
)

def _inputs_analysis_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    action = None
    for candidate in tut[DepActionsInfo].actions:
        if candidate.mnemonic == "Rustc":
            action = candidate
            break
    if action == None:
        fail("No Rustc action found")
    inputs = action.inputs.to_list()
    for expected in ctx.attr.expected_inputs:
        asserts.true(
            env,
            any([input.path.endswith("/" + expected) for input in inputs]),
            "error: expected '{}' to be in inputs: '{}'".format(expected, inputs),
        )

    for expected in ctx.attr.expected_link_arg_inputs:
        asserts.true(
            env,
            any([arg.startswith("-Clink-arg=") and arg.endswith("/" + expected) for arg in action.argv]),
            "error: expected '{}' to be linked via -Clink-arg: '{}'".format(expected, action.argv),
        )

    for expected in ctx.attr.expected_args:
        asserts.true(
            env,
            expected in action.argv,
            "error: expected '{}' in args: '{}'".format(expected, action.argv),
        )

    for unexpected in ctx.attr.unexpected_args:
        asserts.false(
            env,
            unexpected in action.argv,
            "error: did not expect '{}' in args: '{}'".format(unexpected, action.argv),
        )

    runfiles = tut[DepActionsInfo].runfiles
    for expected in ctx.attr.expected_runfiles:
        asserts.true(
            env,
            any([runfile.path.endswith("/" + expected) for runfile in runfiles]),
            "error: expected '{}' to be in runfiles: '{}'".format(expected, runfiles),
        )

    return analysistest.end(env)

inputs_analysis_test = analysistest.make(
    impl = _inputs_analysis_test_impl,
    doc = """An analysistest to examine the inputs of a library target.""",
    attrs = {
        "expected_inputs": attr.string_list(),
        "expected_args": attr.string_list(),
        "expected_link_arg_inputs": attr.string_list(),
        "expected_runfiles": attr.string_list(),
        "unexpected_args": attr.string_list(),
    },
)

def runtime_libs_test(name):
    """Produces test shared and static library targets that are set up to use a custom cc_toolchain with custom runtime libs.

    Args:
      name: The name of the test target.
    """

    test_cc_config(
        name = "%s/cc_toolchain_config" % name,
    )
    cc_toolchain(
        name = "%s/test_cc_toolchain_impl" % name,
        all_files = ":empty",
        compiler_files = ":empty",
        dwp_files = ":empty",
        linker_files = ":empty",
        objcopy_files = ":empty",
        strip_files = ":empty",
        supports_param_files = 0,
        toolchain_config = ":%s/cc_toolchain_config" % name,
        toolchain_identifier = "dummy_wasm32_cc",
        static_runtime_lib = ":dummy.a",
        dynamic_runtime_lib = ":dummy.so",
    )
    native.toolchain(
        name = "%s/test_cc_toolchain" % name,
        toolchain = ":%s/test_cc_toolchain_impl" % name,
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    )

    rust_shared_library(
        name = "%s/__shared_library" % name,
        edition = "2018",
        srcs = ["lib.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_shared_library" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__shared_library" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/shared_library" % name,
        target_under_test = "%s/_shared_library" % name,
        expected_inputs = ["dummy.so"],
        expected_args = select({
            "@platforms//os:windows": ["-ldylib=dummy"],
            "//conditions:default": [],
        }),
        expected_link_arg_inputs = select({
            "@platforms//os:windows": [],
            "//conditions:default": ["dummy.so"],
        }),
        expected_runfiles = ["dummy.so"],
        unexpected_args = select({
            "@platforms//os:windows": [],
            "//conditions:default": ["-ldylib=dummy"],
        }),
    )

    rust_static_library(
        name = "%s/__static_library" % name,
        edition = "2018",
        srcs = ["lib.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_static_library" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__static_library" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/static_library" % name,
        target_under_test = "%s/_static_library" % name,
        expected_inputs = ["dummy.a"],
    )

    rust_binary(
        name = "%s/__binary" % name,
        edition = "2018",
        srcs = ["main.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_binary" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__binary" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/binary" % name,
        target_under_test = "%s/_binary" % name,
        expected_args = ["--codegen=link-arg=-Wl,--retained-link-arg"],
        unexpected_args = [
            "--codegen=link-arg=-unwindlib=none",
            "--codegen=link-arg=--unwindlib=none",
        ],
    )

    rust_binary(
        name = "%s/__binary_with_default_linker_libraries" % name,
        edition = "2018",
        rustc_flags = ["-Cdefault-linker-libraries=yes"],
        srcs = ["main.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_binary_with_default_linker_libraries" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__binary_with_default_linker_libraries" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/binary_with_default_linker_libraries" % name,
        target_under_test = "%s/_binary_with_default_linker_libraries" % name,
        expected_args = [
            "--codegen=link-arg=-unwindlib=none",
            "--codegen=link-arg=--unwindlib=none",
            "--codegen=link-arg=-Wl,--retained-link-arg",
        ],
    )

    rust_binary(
        name = "%s/__binary_with_bare_default_linker_libraries" % name,
        edition = "2018",
        rustc_flags = ["-Cdefault-linker-libraries"],
        srcs = ["main.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_binary_with_bare_default_linker_libraries" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__binary_with_bare_default_linker_libraries" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/binary_with_bare_default_linker_libraries" % name,
        target_under_test = "%s/_binary_with_bare_default_linker_libraries" % name,
        expected_args = [
            "--codegen=link-arg=-unwindlib=none",
            "--codegen=link-arg=--unwindlib=none",
            "--codegen=link-arg=-Wl,--retained-link-arg",
        ],
    )

    rust_binary(
        name = "%s/__binary_with_disabled_default_linker_libraries" % name,
        edition = "2018",
        rustc_flags = [
            "-Cdefault-linker-libraries=yes",
            "-Cdefault-linker-libraries=no",
        ],
        srcs = ["main.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_binary_with_disabled_default_linker_libraries" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__binary_with_disabled_default_linker_libraries" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/binary_with_disabled_default_linker_libraries" % name,
        target_under_test = "%s/_binary_with_disabled_default_linker_libraries" % name,
        expected_args = ["--codegen=link-arg=-Wl,--retained-link-arg"],
        unexpected_args = [
            "--codegen=link-arg=-unwindlib=none",
            "--codegen=link-arg=--unwindlib=none",
        ],
    )

    write_file(
        name = "%s/default_linker_libraries_flags" % name,
        out = "%s/default_linker_libraries.rustc_flags" % name,
        content = ["-Cdefault-linker-libraries=yes"],
    )

    rust_binary(
        name = "%s/__binary_with_response_file" % name,
        compile_data = ["%s/default_linker_libraries_flags" % name],
        edition = "2018",
        rustc_flags = ["@$(location %s/default_linker_libraries_flags)" % name],
        srcs = ["main.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_binary_with_response_file" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__binary_with_response_file" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/binary_with_response_file" % name,
        target_under_test = "%s/_binary_with_response_file" % name,
        expected_args = [
            "--codegen=link-arg=-unwindlib=none",
            "--codegen=link-arg=--unwindlib=none",
            "--codegen=link-arg=-Wl,--retained-link-arg",
        ],
    )
