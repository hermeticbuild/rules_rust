"""Unit tests for rust toolchains."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_rust_toolchain_test_target_json//:defs.bzl", "TARGET_JSON")
load("//rust:defs.bzl", "rust_clippy_aspect", "rust_library", "rust_lto_flag")
load("//rust:toolchain.bzl", "rust_stdlib_filegroup", "rust_toolchain")
load("//rust/platform:triple.bzl", "triple")

def _toolchain_specifies_target_triple_test_impl(ctx):
    env = analysistest.begin(ctx)
    toolchain_info = analysistest.target_under_test(env)[platform_common.ToolchainInfo]

    asserts.equals(env, None, toolchain_info.target_json)
    asserts.equals(env, "toolchain-test-triple", toolchain_info.target_flag_value)
    asserts.equals(env, triple("toolchain-test-triple"), toolchain_info.target_triple)
    asserts.equals(env, "toolchain", toolchain_info.target_arch)

    return analysistest.end(env)

def _toolchain_specifies_target_json_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    toolchain_info = target[platform_common.ToolchainInfo]

    asserts.equals(env, None, toolchain_info.target_triple)
    asserts.equals(env, "x86_64", toolchain_info.target_arch)

    # The specific name here is not as valuable as identifying that `target_json` is a json file
    expected_basename = "{}.target.json".format(target.label.name)
    asserts.equals(env, expected_basename, toolchain_info.target_json.basename)

    # The value is expected to be to a generated file in bazel-out.
    asserts.equals(env, "File", type(toolchain_info.target_flag_value))
    target_path = toolchain_info.target_flag_value.path
    asserts.true(env, target_path.startswith("bazel-out/"))
    asserts.true(env, target_path.endswith("/bin/{}/{}".format(ctx.label.package, expected_basename)))

    return analysistest.end(env)

def _toolchain_location_expands_linkflags_impl(ctx):
    env = analysistest.begin(ctx)
    toolchain_info = analysistest.target_under_test(env)[platform_common.ToolchainInfo]

    asserts.equals(
        env,
        "test:test/unit/toolchain/config.txt",
        toolchain_info.stdlib_linkflags.linking_context.linker_inputs.to_list()[0].user_link_flags[0],
    )
    asserts.equals(
        env,
        "test:sysroot=" + toolchain_info.sysroot,
        toolchain_info.stdlib_linkflags.linking_context.linker_inputs.to_list()[0].user_link_flags[1],
    )

    return analysistest.end(env)

def _toolchain_location_expands_extra_rustc_flags_impl(ctx):
    env = analysistest.begin(ctx)
    toolchain_info = analysistest.target_under_test(env)[platform_common.ToolchainInfo]

    asserts.equals(
        env,
        "extra_rustc_flags:test/unit/toolchain/config.txt",
        toolchain_info.extra_rustc_flags[0],
    )
    asserts.equals(
        env,
        "extra_rustc_flags:sysroot=" + toolchain_info.sysroot,
        toolchain_info.extra_rustc_flags[1],
    )

    return analysistest.end(env)

def _toolchain_uses_custom_lto_flag_test_impl(ctx):
    env = analysistest.begin(ctx)
    toolchain_info = analysistest.target_under_test(env)[platform_common.ToolchainInfo]

    asserts.equals(env, "fat", toolchain_info.lto.mode)

    return analysistest.end(env)

def _std_libs_support_srcs_outside_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    symlinks = [a for a in actions if a.mnemonic == "Symlink"]
    asserts.equals(env, 2, len(symlinks))

    rlib_symlink = symlinks[0].outputs.to_list()[0]
    asserts.equals(env, tut.label.package + "/core.rlib", rlib_symlink.short_path)

    a_symlink = symlinks[1].outputs.to_list()[0]
    asserts.equals(env, tut.label.package + "/libcore.a", a_symlink.short_path)

    return analysistest.end(env)

def _forwarded_rustc_lib_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    rustc_lib = target[platform_common.ToolchainInfo].rustc_lib.to_list()
    asserts.equals(
        env,
        ["%s/%s/defs.bzl" % (target.label.package, target.label.name)],
        [file.short_path for file in rustc_lib],
    )
    return analysistest.end(env)

def _compile_tool_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    rustc_actions = analysistest.target_actions(env)
    clippy_actions = analysistest.target_under_test(env).actions
    rustc_inputs = [file.basename for action in rustc_actions if action.mnemonic == "Rustc" for file in action.inputs.to_list()]
    clippy_inputs = [file.basename for action in clippy_actions if action.mnemonic == "Clippy" for file in action.inputs.to_list()]

    for basename in ["mock_rustc.exe", "defs.bzl"]:
        asserts.true(env, basename in rustc_inputs, "Rustc input missing: %s" % basename)
    for basename in ["mock_rustdoc.exe", "mock_clippy.exe", "toolchain-test-triple.json"]:
        asserts.false(env, basename in rustc_inputs, "Unexpected Rustc input: %s" % basename)
    for basename in ["mock_clippy.exe", "toolchain-test-triple.json"]:
        asserts.true(env, basename in clippy_inputs, "Clippy input missing: %s" % basename)
    return analysistest.end(env)

forwarded_rustc_lib_test = analysistest.make(_forwarded_rustc_lib_test_impl)
compile_tool_inputs_test = analysistest.make(
    _compile_tool_inputs_test_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": [str(Label(":test_toolchain"))],
    },
    extra_target_under_test_aspects = [rust_clippy_aspect],
)

toolchain_specifies_target_triple_test = analysistest.make(_toolchain_specifies_target_triple_test_impl)
toolchain_specifies_target_json_test = analysistest.make(_toolchain_specifies_target_json_test_impl)
toolchain_location_expands_linkflags_test = analysistest.make(_toolchain_location_expands_linkflags_impl)
toolchain_location_expands_extra_rustc_flags_test = analysistest.make(_toolchain_location_expands_extra_rustc_flags_impl)
toolchain_uses_custom_lto_flag_test = analysistest.make(_toolchain_uses_custom_lto_flag_test_impl)
std_libs_support_srcs_outside_package_test = analysistest.make(_std_libs_support_srcs_outside_package_test_impl)

def _define_test_targets():
    native.filegroup(
        name = "stdlib_srcs",
        srcs = ["config.txt"],
    )
    rust_stdlib_filegroup(
        name = "std_libs",
        srcs = [":stdlib_srcs"],
    )

    rust_stdlib_filegroup(
        name = "std_libs_with_srcs_outside_package",
        srcs = ["//test/unit/toolchain/subpackage:std_libs_srcs"],
    )

    native.filegroup(
        name = "target_json",
        srcs = ["toolchain-test-triple.json"],
    )

    write_file(
        name = "mock_rustc",
        out = "mock_rustc.exe",
        content = [],
        is_executable = True,
    )

    write_file(
        name = "mock_rust_lld",
        out = "mock_rust_lld.exe",
        content = [],
        is_executable = True,
    )

    write_file(
        name = "mock_rustdoc",
        out = "mock_rustdoc.exe",
        content = [],
        is_executable = True,
    )

    native.filegroup(
        name = "forwarded_rustc_lib",
        srcs = ["@rules_rust_toolchain_test_target_json//:defs.bzl"],
    )

    write_file(
        name = "mock_clippy_bin",
        out = "mock_clippy.exe",
        content = [],
        is_executable = True,
    )

    native.filegroup(
        name = "mock_clippy",
        srcs = [":mock_clippy_bin"],
        data = ["toolchain-test-triple.json"],
    )

    rust_toolchain(
        name = "rust_triple_toolchain",
        binary_ext = "",
        clippy_driver = ":mock_clippy",
        dylib_ext = ".so",
        exec_triple = "x86_64-unknown-none",
        linker = ":mock_rust_lld",
        process_wrapper = "//util/process_wrapper:bootstrap_process_wrapper",
        rust_doc = ":mock_rustdoc",
        rust_std = ":std_libs",
        rustc = ":mock_rustc",
        rustc_lib = ":forwarded_rustc_lib",
        staticlib_ext = ".a",
        stdlib_linkflags = [],
        target_triple = "toolchain-test-triple",
    )

    native.toolchain(
        name = "test_toolchain",
        toolchain = ":rust_triple_toolchain",
        toolchain_type = "//rust:toolchain_type",
    )

    write_file(
        name = "compile_tool_inputs_src",
        out = "compile_tool_inputs.rs",
        content = [],
    )

    rust_library(
        name = "compile_tool_inputs_library",
        srcs = [":compile_tool_inputs_src"],
        edition = "2018",
        tags = ["manual"],
    )

    encoded_target_json = json.encode(TARGET_JSON)

    rust_toolchain(
        name = "rust_json_toolchain",
        binary_ext = "",
        dylib_ext = ".so",
        exec_triple = "x86_64-unknown-none",
        rust_doc = ":mock_rustdoc",
        rust_std = ":std_libs",
        rustc = ":mock_rustc",
        process_wrapper = "@rules_rust//util/process_wrapper",
        linker = ":mock_rust_lld",
        staticlib_ext = ".a",
        stdlib_linkflags = [],
        target_json = encoded_target_json,
    )

    rust_toolchain(
        name = "rust_inline_json_toolchain",
        binary_ext = "",
        dylib_ext = ".so",
        exec_triple = "x86_64-unknown-none",
        rust_doc = ":mock_rustdoc",
        rust_std = ":std_libs",
        rustc = ":mock_rustc",
        process_wrapper = "@rules_rust//util/process_wrapper",
        linker = ":mock_rust_lld",
        staticlib_ext = ".a",
        stdlib_linkflags = [],
        target_json = json.encode(
            {
                "arch": "x86_64",
                "env": "gnu",
                "llvm-target": "x86_64-unknown-linux-gnu",
                "target-family": ["unix"],
                "target-pointer-width": "64",
            },
        ),
    )

    rust_toolchain(
        name = "rust_location_expand_toolchain",
        binary_ext = "",
        dylib_ext = ".so",
        exec_triple = "x86_64-unknown-none",
        rust_doc = ":mock_rustdoc",
        rust_std = ":std_libs",
        rustc = ":mock_rustc",
        process_wrapper = "@rules_rust//util/process_wrapper",
        linker = ":mock_rust_lld",
        staticlib_ext = ".a",
        stdlib_linkflags = ["test:$(location :stdlib_srcs)", "test:sysroot=$(RUST_SYSROOT)"],
        extra_rustc_flags = ["extra_rustc_flags:$(location :stdlib_srcs)", "extra_rustc_flags:sysroot=$(RUST_SYSROOT)"],
        target_json = encoded_target_json,
    )

    rust_lto_flag(
        name = "fat_lto",
        build_setting_default = "fat",
    )

    rust_toolchain(
        name = "rust_custom_lto_toolchain",
        binary_ext = "",
        dylib_ext = ".so",
        exec_triple = "x86_64-unknown-none",
        lto = ":fat_lto",
        process_wrapper = "//util/process_wrapper",
        rust_doc = ":mock_rustdoc",
        rust_std = ":std_libs",
        rustc = ":mock_rustc",
        linker = ":mock_rust_lld",
        staticlib_ext = ".a",
        stdlib_linkflags = [],
        target_triple = "toolchain-test-triple",
    )

def toolchain_test_suite(name):
    """Entry-point macro called from the BUILD file.

    Args:
        name (str): The name of the test suite.
    """
    _define_test_targets()

    toolchain_specifies_target_triple_test(
        name = "toolchain_specifies_target_triple_test",
        target_under_test = ":rust_triple_toolchain",
    )
    toolchain_specifies_target_json_test(
        name = "toolchain_specifies_target_json_test",
        target_under_test = ":rust_json_toolchain",
    )
    toolchain_specifies_target_json_test(
        name = "toolchain_specifies_inline_target_json_test",
        target_under_test = ":rust_inline_json_toolchain",
    )
    toolchain_location_expands_linkflags_test(
        name = "toolchain_location_expands_linkflags_test",
        target_under_test = ":rust_location_expand_toolchain",
    )
    toolchain_location_expands_extra_rustc_flags_test(
        name = "toolchain_location_expands_extra_rustc_flags_test",
        target_under_test = ":rust_location_expand_toolchain",
    )
    toolchain_uses_custom_lto_flag_test(
        name = "toolchain_uses_custom_lto_flag_test",
        target_under_test = ":rust_custom_lto_toolchain",
    )
    std_libs_support_srcs_outside_package_test(
        name = "std_libs_support_srcs_outside_package_test",
        target_under_test = ":std_libs_with_srcs_outside_package",
    )

    forwarded_rustc_lib_test(
        name = "forwarded_rustc_lib_test",
        target_under_test = ":rust_triple_toolchain",
    )

    compile_tool_inputs_test(
        name = "compile_tool_inputs_test",
        target_under_test = ":compile_tool_inputs_library",
    )

    native.test_suite(
        name = name,
        tests = [
            ":toolchain_specifies_target_triple_test",
            ":toolchain_specifies_target_json_test",
            ":toolchain_specifies_inline_target_json_test",
            ":toolchain_location_expands_linkflags_test",
            ":toolchain_location_expands_extra_rustc_flags_test",
            ":toolchain_uses_custom_lto_flag_test",
            ":std_libs_support_srcs_outside_package_test",
            ":forwarded_rustc_lib_test",
            ":compile_tool_inputs_test",
        ],
    )
