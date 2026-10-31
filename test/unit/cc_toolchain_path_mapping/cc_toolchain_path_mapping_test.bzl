"""Tests C++ toolchain arguments with and without --experimental_output_paths=strip."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "action_config", "env_entry", "env_set", "feature", "flag_group", "flag_set", "tool")
load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")
load("//rust:defs.bzl", "rust_binary")

# buildifier: disable=bzl-visibility
load("//rust/private:rustc.bzl", "get_linker_and_args")
load("//test/unit:common.bzl", "assert_argv_contains")

def _cc_toolchain_config_impl(ctx):
    linker = ctx.actions.declare_file(ctx.label.name + "/linker")
    script = ctx.actions.declare_file(ctx.label.name + "/linker.ld")
    ctx.actions.write(linker, "", is_executable = True)
    ctx.actions.write(script, "SECTIONS {}")
    return [
        DefaultInfo(files = depset([linker, script])),
        cc_common.create_cc_toolchain_config_info(
            ctx = ctx,
            action_configs = [action_config(
                action_name = ACTION_NAMES.cpp_link_executable,
                enabled = True,
                tools = [tool(tool = linker)],
            )],
            features = [feature(
                name = "generated_linker_inputs",
                enabled = True,
                flag_sets = [flag_set(
                    actions = [ACTION_NAMES.cpp_link_executable],
                    flag_groups = [flag_group(flags = [
                        "-Wl,-T,%{path:" + script.path + "}",
                        "-Wl,--as-needed",
                    ])],
                )],
                env_sets = [env_set(
                    actions = [ACTION_NAMES.cpp_link_executable],
                    env_entries = [env_entry(
                        key = "LIB",
                        value = "%{path:" + script.dirname + "}",
                    )],
                )],
            ), feature(
                name = "direct_msvc",
                flag_sets = [flag_set(
                    actions = [ACTION_NAMES.cpp_link_executable],
                    flag_groups = [flag_group(flags = [
                        "/clang:-Xlinker",
                        "/clang:/LIBPATH:sdk/lib",
                        "/clang:-Xlinker",
                        "/clang:/MACHINE:X64",
                        "/clang:-Xlinker",
                        "/clang:/vfsoverlay:sdk.json",
                        "/clang:-Xlinker",
                        "/clang:/lldignoreenv",
                        "-fuse-ld=lld",
                        "-L",
                        "driver-only",
                        "--sysroot=driver-only",
                    ])],
                )],
            )],
            toolchain_identifier = "path-mapping-test-toolchain",
            host_system_name = "unknown",
            target_system_name = "unknown",
            target_cpu = "unknown",
            target_libc = "unknown",
            compiler = "unknown",
            abi_version = "unknown",
            abi_libc_version = "unknown",
        ),
    ]

_cc_toolchain_config = rule(
    implementation = _cc_toolchain_config_impl,
    provides = [CcToolchainConfigInfo],
)

def _extra_toolchain_transition_impl(_settings, attr):
    return {"//command_line_option:extra_toolchains": [attr.extra_toolchain]}

_extra_toolchain_transition = transition(
    implementation = _extra_toolchain_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:extra_toolchains"],
)

_RustcActionsInfo = provider(fields = {"actions": "Rustc actions from rust_binary."})

def _subject_impl(ctx):
    return [_RustcActionsInfo(actions = ctx.attr.target[0].actions)]

_subject = rule(
    implementation = _subject_impl,
    attrs = {
        "extra_toolchain": attr.string(),
        "target": attr.label(cfg = _extra_toolchain_transition),
    },
)

def _expected_path(file, strip):
    return "bazel-out/cfg/" + file.path.split("/", 2)[2] if strip else file.path

def _cc_toolchain_path_mapping_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    action = [action for action in target[_RustcActionsInfo].actions if action.mnemonic == "Rustc"][0]
    inputs = {file.basename: file for file in action.inputs.to_list()}
    linker = inputs["linker"]
    script = inputs["linker.ld"]
    asserts.false(env, linker.is_source)
    asserts.false(env, script.is_source)

    # action.argv expands Args with the Rustc action's PathMapper. The output
    # argument confirms that --experimental_output_paths=strip takes effect.
    output = [file for file in action.outputs.to_list() if file.basename in ["binary", "binary.exe"]][0]
    assert_argv_contains(env, action, "--emit=link=" + _expected_path(output, ctx.attr.strip))
    assert_argv_contains(env, action, "--codegen=linker=" + _expected_path(linker, ctx.attr.strip))
    script_path = _expected_path(script, ctx.attr.strip)
    assert_argv_contains(env, action, "--codegen=link-arg=-Wl,-T," + script_path)
    assert_argv_contains(env, action, "--codegen=link-arg=-LIBPATH:" + script_path.rsplit("/", 1)[0])
    assert_argv_contains(env, action, "--codegen=link-arg=-Wl,--as-needed")
    return analysistest.end(env)

_cc_toolchain_path_mapping_test = analysistest.make(
    _cc_toolchain_path_mapping_test_impl,
    attrs = {"strip": attr.bool()},
    config_settings = {
        str(Label("//rust/settings:toolchain_linker_preference")): "cc",
    },
)

def _direct_msvc_linker_args_test_impl(ctx):
    env = analysistest.begin(ctx)
    cc_toolchain = analysistest.target_under_test(env)[platform_common.ToolchainInfo].cc
    features = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ["direct_msvc"],
        unsupported_features = ["generated_linker_inputs"],
    )
    linker = cc_common.get_tool_for_action(
        feature_configuration = features,
        action_name = ACTION_NAMES.cpp_link_executable,
    )
    for preference in ["rust", None]:
        toolchain = struct(
            linker = struct(path = "rust-lld"),
            linker_preference = preference,
            linker_type = "direct",
            target_arch = "x86_64",
            target_os = "windows",
            target_abi = "msvc",
        )
        path, direct, args, _env = get_linker_and_args(ctx, "bin", toolchain, cc_toolchain, features, depset())
        if preference == "rust":
            asserts.equals(env, "rust-lld", path)
            asserts.true(env, direct)
            asserts.equals(env, ["/LIBPATH:sdk/lib", "/MACHINE:X64", "/vfsoverlay:sdk.json", "/lldignoreenv"], args)
        else:
            # Merely configuring a Rust linker must not change the default.
            asserts.equals(env, linker, path)
            asserts.false(env, direct)
            asserts.true(env, "/clang:-Xlinker" in args)
    return analysistest.end(env)

_direct_msvc_linker_args_test = analysistest.make(
    _direct_msvc_linker_args_test_impl,
    fragments = ["cpp"],
)

def cc_toolchain_path_mapping_test_suite(name):
    """Registers a regression that also runs with --experimental_output_paths=strip."""
    _cc_toolchain_config(name = "cc_toolchain_config")
    cc_toolchain(
        name = "cc_toolchain_impl",
        all_files = ":cc_toolchain_config",
        compiler_files = ":cc_toolchain_config",
        dwp_files = ":cc_toolchain_config",
        linker_files = ":cc_toolchain_config",
        objcopy_files = ":cc_toolchain_config",
        strip_files = ":cc_toolchain_config",
        toolchain_config = ":cc_toolchain_config",
        toolchain_identifier = "path-mapping-test-toolchain",
    )
    native.toolchain(
        name = "cc_toolchain",
        toolchain = ":cc_toolchain_impl",
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    )
    rust_binary(
        name = "binary",
        srcs = ["main.rs"],
        tags = ["manual", "nobuild"],
    )
    _subject(
        name = "subject",
        extra_toolchain = "//%s:cc_toolchain" % native.package_name(),
        target = ":binary",
        tags = ["manual"],
    )
    native.config_setting(
        name = "strip_output_paths",
        values = {"experimental_output_paths": "strip"},
    )
    _cc_toolchain_path_mapping_test(
        name = "cc_toolchain_path_mapping_test",
        strip = select({
            ":strip_output_paths": True,
            "//conditions:default": False,
        }),
        target_under_test = ":subject",
    )
    _direct_msvc_linker_args_test(
        name = "direct_msvc_linker_args_test",
        target_under_test = "cc_toolchain_impl",
    )
    native.test_suite(
        name = name,
        tests = [":cc_toolchain_path_mapping_test", "direct_msvc_linker_args_test"],
    )
