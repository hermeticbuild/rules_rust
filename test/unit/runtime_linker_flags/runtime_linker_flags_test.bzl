"""Regression tests for redundant Clang runtime-selection flags."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//rust:defs.bzl", "rust_binary")

# buildifier: disable=bzl-visibility
load("//rust/private:runtime_linker_flags.bzl", "can_omit_runtime_selection", "omit_unused_runtime_selection")

def _default_libraries_test_impl(ctx):
    env = unittest.begin(ctx)
    for flags in [
        [],
        ["--edition=2021", "-Copt-level=2"],
        ["-Cdefault-linker-libraries=no"],
        ["-C", "default-linker-libraries=false"],
        ["--codegen=default-linker-libraries=off"],
        ["--codegen", "default-linker-libraries=0"],
        ["-Cdefault-linker-libraries=yes", "-Cdefault-linker-libraries=no"],
    ]:
        asserts.true(env, can_omit_runtime_selection(flags), str(flags))
    for flags in [
        ["-Cdefault-linker-libraries"],
        ["-C", "default-linker-libraries=yes"],
        ["--codegen=default-linker-libraries=true"],
        ["--codegen", "default-linker-libraries=on"],
        ["-C=default-linker-libraries=1"],
        ["-Cdefault-linker-libraries=no", "-Cdefault-linker-libraries=yes"],
        ["-Cdefault-linker-libraries=invalid"],
        ["-C"],
        ["@flags.txt"],
        ["--target=custom.json"],
        [("--cfg=%s", "file")],
        ["-Clinker=other-driver"],
    ]:
        asserts.false(env, can_omit_runtime_selection(flags), str(flags))
    asserts.false(env, can_omit_runtime_selection(ctx.actions.args()))
    return unittest.end(env)

def _filter_test_impl(ctx):
    env = unittest.begin(ctx)
    kept = ["-target", "x86_64-linux-gnu", "--sysroot=/dev/null", "-fuse-ld=lld", "-Lruntime", "-nostdlib++", "-Wl,--as-needed", "-lunwind", "--unwindlib=libunwind", "-rtlib=libgcc"]
    original = kept[:4] + ["--unwindlib=none", "-rtlib=compiler-rt", "-unwindlib=none", "--rtlib=compiler-rt"] + kept[4:]
    asserts.equals(env, kept, omit_unused_runtime_selection(original))
    return unittest.end(env)

default_libraries_test = unittest.make(_default_libraries_test_impl)
filter_test = unittest.make(_filter_test_impl)

def _link_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = [a for a in analysistest.target_actions(env) if a.mnemonic == "Rustc"][0]
    asserts.true(env, any([arg.startswith("--codegen=linker=") and arg.endswith("/clang++") for arg in action.argv]))
    for flag in ("--unwindlib=none", "-rtlib=compiler-rt"):
        asserts.equals(env, ctx.attr.preserve, "--codegen=link-arg=" + flag in action.argv, flag)
    asserts.true(env, any([arg.startswith("--codegen=link-arg=-fuse-ld=") for arg in action.argv]))
    return analysistest.end(env)

def _link_action_test(platform):
    return analysistest.make(
        _link_action_test_impl,
        attrs = {"preserve": attr.bool()},
        config_settings = {
            "//command_line_option:extra_toolchains": [str(Label("@llvm//toolchain:all"))],
            "//command_line_option:platforms": str(Label(":" + platform)),
            "//command_line_option:linkopt": ["--unwindlib=none", "-rtlib=compiler-rt"],
        },
    )

linux_link_action_test = _link_action_test("linux")
macos_link_action_test = _link_action_test("macos")

def runtime_linker_flags_test_suite(name):
    """Define pure flag tests and real Clang toolchain action regressions.

    Args:
        name: Name of the pure flag test suite.
    """
    native.platform(name = "macos", constraint_values = ["@platforms//os:macos", "@platforms//cpu:aarch64"])
    native.platform(name = "linux", constraint_values = ["@platforms//os:linux", "@platforms//cpu:x86_64"])
    for suffix, flags, preserve in [
        ("default", [], False),
        ("enabled", ["-Cdefault-linker-libraries=yes"], True),
        ("disabled_last", ["-Cdefault-linker-libraries=yes", "-C", "default-linker-libraries=no"], False),
    ]:
        rust_binary(name = suffix + "_bin", srcs = ["main.rs"], rustc_flags = flags, tags = ["manual"])
        linux_link_action_test(name = suffix + "_linux_action_test", target_under_test = ":" + suffix + "_bin", preserve = preserve)
        macos_link_action_test(name = suffix + "_macos_action_test", target_under_test = ":" + suffix + "_bin", preserve = preserve)
    unittest.suite(name, default_libraries_test, filter_test)
