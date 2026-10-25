"""Rust MSVC links use LINK arguments while Cargo preserves C++ driver arguments."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "action_config", "feature", "flag_group", "flag_set", "tool")
load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")
load("//cargo:defs.bzl", "cargo_build_script")
load("//rust:defs.bzl", "rust_binary")
load("//rust:toolchain.bzl", "rust_stdlib_filegroup", "rust_toolchain")
load("//test/unit:common.bzl", "assert_argv_contains", "assert_argv_contains_not", "assert_argv_contains_prefix_not")

_LINK_FLAGS = [
    "/MD",
    "/clang:--target=x86_64-pc-windows-msvc",
    "/clang:-Xlinker",
    "/clang:/LIBPATH:C:/Program Files/Windows Kits/Lib",
    "/link",
    "/OPT:REF",
]

def _cc_config_impl(ctx):
    clang_cl = ctx.actions.declare_file(ctx.label.name + "/clang-cl")
    lld_link = ctx.actions.declare_file(ctx.label.name + "/lld-link")
    overlay = ctx.file._sdk_overlay
    ctx.actions.write(clang_cl, "", is_executable = True)
    ctx.actions.write(lld_link, "", is_executable = True)
    return [
        DefaultInfo(files = depset([clang_cl, lld_link, overlay])),
        cc_common.create_cc_toolchain_config_info(
            ctx = ctx,
            action_configs = [
                action_config(
                    action_name = action,
                    enabled = True,
                    tools = [tool(tool = clang_cl)],
                )
                for action in [
                    ACTION_NAMES.c_compile,
                    ACTION_NAMES.cpp_compile,
                    ACTION_NAMES.cpp_link_executable,
                    ACTION_NAMES.cpp_link_static_library,
                ]
            ],
            features = [feature(
                name = "msvc_driver_link_flags",
                enabled = True,
                flag_sets = [flag_set(
                    actions = [ACTION_NAMES.cpp_link_executable],
                    flag_groups = [flag_group(flags = [
                        "/clang:-Xlinker",
                        "/clang:/vfsoverlay:" + overlay.path,
                    ] + _LINK_FLAGS)],
                )],
            )],
            toolchain_identifier = "msvc-linker-test",
            host_system_name = "unknown",
            target_system_name = "windows",
            target_cpu = "x86_64",
            target_libc = "msvcrt",
            compiler = "clang-cl",
            abi_version = "unknown",
            abi_libc_version = "unknown",
        ),
    ]

_cc_config = rule(
    implementation = _cc_config_impl,
    attrs = {"_sdk_overlay": attr.label(default = ":sdk-overlay.yaml", allow_single_file = True)},
    provides = [CcToolchainConfigInfo],
)

_MSVC_CONFIG = {
    "//command_line_option:extra_toolchains": [
        str(Label(":cc_toolchain")),
        str(Label(":rust_toolchain")),
    ],
    "//command_line_option:platforms": [str(Label(":windows_x86_64"))],
    str(Label("//rust/settings:toolchain_linker_preference")): "cc",
}

def _expected_path(file, strip):
    return "bazel-out/cfg/" + file.path.split("/", 2)[2] if strip else file.path

def _rust_msvc_linker_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    action = [action for action in target.actions if action.mnemonic == "Rustc"][0]
    inputs = {file.basename: file for file in action.inputs.to_list()}
    asserts.true(env, "lld-link" in inputs, "lld-link must be a declared Rustc input")
    asserts.true(env, "sdk-overlay.yaml" in inputs, "the SDK overlay must be a declared Rustc input")
    assert_argv_contains(env, action, "--codegen=linker=" + _expected_path(inputs["lld-link"], ctx.attr.strip))
    assert_argv_contains(env, action, "--codegen=link-arg=/vfsoverlay:" + inputs["sdk-overlay.yaml"].path)
    assert_argv_contains(env, action, "--codegen=link-arg=/LIBPATH:C:/Program Files/Windows Kits/Lib")
    assert_argv_contains(env, action, "--codegen=link-arg=/OPT:REF")
    assert_argv_contains_not(env, action, "--codegen=linker=" + _expected_path(inputs["clang-cl"], ctx.attr.strip))
    for flag in ["/MD", "--target=x86_64-pc-windows-msvc", "/link", "-Xlinker"]:
        assert_argv_contains_not(env, action, "--codegen=link-arg=" + flag)
    assert_argv_contains_prefix_not(env, action, "--codegen=link-arg=/clang:")
    return analysistest.end(env)

_rust_msvc_linker_test = analysistest.make(
    _rust_msvc_linker_test_impl,
    attrs = {"strip": attr.bool()},
    config_settings = _MSVC_CONFIG,
)

def _cargo_msvc_linker_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    action = [action for action in target.actions if action.mnemonic == "CargoBuildScriptRun"][0]
    inputs = {file.basename: file for file in action.inputs.to_list()}
    asserts.equals(env, inputs["clang-cl"].path, action.env.get("LD"))

    # Cargo sends these arguments to a C/C++ driver. Preserve the complete
    # argument sequence, including the value with spaces, rather than LINK args.
    asserts.true(env, " ".join(_LINK_FLAGS) in action.env.get("LDFLAGS", ""))
    return analysistest.end(env)

_cargo_msvc_linker_test = analysistest.make(
    _cargo_msvc_linker_test_impl,
    config_settings = _MSVC_CONFIG,
)

def msvc_linker_test_suite(name):
    """Registers Rustc and Cargo tests against a generated clang-cl toolchain.

    Args:
        name: Name of the test suite.
    """
    native.platform(
        name = "windows_x86_64",
        constraint_values = ["@platforms//cpu:x86_64", "@platforms//os:windows"],
    )
    _cc_config(name = "cc_config")
    cc_toolchain(
        name = "cc_impl",
        all_files = ":cc_config",
        ar_files = ":cc_config",
        compiler_files = ":cc_config",
        dwp_files = ":cc_config",
        linker_files = ":cc_config",
        objcopy_files = ":cc_config",
        strip_files = ":cc_config",
        toolchain_config = ":cc_config",
        toolchain_identifier = "msvc-linker-test",
    )
    native.toolchain(
        name = "cc_toolchain",
        target_compatible_with = ["@platforms//cpu:x86_64", "@platforms//os:windows"],
        toolchain = ":cc_impl",
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    )

    # The ordinary Rust registration does not include Linux-to-Windows targets.
    # These tools are sufficient to analyze actions and are never executed.
    for tool_name in ["rustc", "rustdoc", "cargo", "process_wrapper"]:
        write_file(
            name = "mock_" + tool_name,
            out = "mock/" + tool_name,
            content = [],
            is_executable = True,
        )
    rust_stdlib_filegroup(name = "mock_std", srcs = ["main.rs"])
    rust_toolchain(
        name = "rust_impl",
        binary_ext = ".exe",
        cargo = ":mock_cargo",
        default_edition = "2021",
        dylib_ext = ".dll",
        exec_triple = "x86_64-unknown-linux-gnu",
        process_wrapper = ":mock_process_wrapper",
        rust_doc = ":mock_rustdoc",
        rust_std = ":mock_std",
        rustc = ":mock_rustc",
        staticlib_ext = ".lib",
        stdlib_linkflags = [],
        target_triple = "x86_64-pc-windows-msvc",
    )
    native.toolchain(
        name = "rust_toolchain",
        target_compatible_with = ["@platforms//cpu:x86_64", "@platforms//os:windows"],
        toolchain = ":rust_impl",
        toolchain_type = "//rust:toolchain_type",
    )
    rust_binary(
        name = "binary",
        srcs = ["main.rs"],
        tags = ["manual", "nobuild"],
    )
    cargo_build_script(
        name = "build_script",
        srcs = ["main.rs"],
        crate_root = "main.rs",
        tags = ["manual", "nobuild"],
    )
    native.config_setting(
        name = "strip_output_paths",
        values = {"experimental_output_paths": "strip"},
    )
    _rust_msvc_linker_test(
        name = "rust_msvc_linker_test",
        strip = select({
            ":strip_output_paths": True,
            "//conditions:default": False,
        }),
        target_under_test = ":binary",
    )
    _cargo_msvc_linker_test(
        name = "cargo_msvc_linker_test",
        target_under_test = ":build_script",
    )
    native.test_suite(
        name = name,
        tests = [":rust_msvc_linker_test", ":cargo_msvc_linker_test"],
    )
