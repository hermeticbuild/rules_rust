"""Tests for rust_test sharding support."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("//rust:defs.bzl", "rust_test")

# buildifier: disable=bzl-visibility
load("//rust/private:rust.bzl", _rust_test_rule = "rust_test")

def _sharding_enabled_test(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    executable = tut[DefaultInfo].files_to_run.executable

    asserts.true(
        env,
        executable.basename.endswith("_sharding_wrapper.sh") or
        executable.basename.endswith("_sharding_wrapper.bat"),
        "Expected sharding wrapper script, got: " + executable.basename,
    )

    return analysistest.end(env)

sharding_enabled_test = analysistest.make(_sharding_enabled_test)

ParentRunfilesInfo = provider(
    doc = "The basenames of the runfiles the parent rust_test returned to the extending rule.",
    fields = ["basenames"],
)

def _extended_rust_test_impl(ctx):
    providers = []
    for provider in ctx.super():
        if type(provider) == "DefaultInfo":
            providers.append(ParentRunfilesInfo(
                basenames = [f.basename for f in provider.default_runfiles.files.to_list()],
            ))
        providers.append(provider)
    return providers

# The DefaultInfo that ctx.super() returns hides the parent's executable, so an
# extending rule has to find it in the parent's runfiles.
extended_rust_test = rule(
    implementation = _extended_rust_test_impl,
    parent = _rust_test_rule,
)

def _sharding_wrapper_in_runfiles_test(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    basenames = tut[ParentRunfilesInfo].basenames
    wrappers = [
        tut.label.name + "_sharding_wrapper.sh",
        tut.label.name + "_sharding_wrapper.bat",
    ]

    asserts.true(
        env,
        [b for b in basenames if b in wrappers],
        "Expected one of {} in the parent's runfiles, got {}".format(wrappers, basenames),
    )

    return analysistest.end(env)

sharding_wrapper_in_runfiles_test = analysistest.make(_sharding_wrapper_in_runfiles_test)

def _sharding_disabled_test(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    executable = tut[DefaultInfo].files_to_run.executable

    asserts.false(
        env,
        executable.basename.endswith("_sharding_wrapper.sh") or
        executable.basename.endswith("_sharding_wrapper.bat"),
        "Expected test binary, not wrapper script: " + executable.basename,
    )

    return analysistest.end(env)

sharding_disabled_test = analysistest.make(_sharding_disabled_test)

def _test_sharding_targets():
    rust_test(
        name = "sharded_test_enabled",
        srcs = ["sharded_test.rs"],
        edition = "2021",
        experimental_enable_sharding = True,
    )

    sharding_enabled_test(
        name = "sharding_enabled_test",
        target_under_test = ":sharded_test_enabled",
    )

    extended_rust_test(
        name = "sharded_test_extended",
        srcs = ["sharded_test.rs"],
        edition = "2021",
        experimental_enable_sharding = True,
        tags = ["manual"],
    )

    sharding_wrapper_in_runfiles_test(
        name = "sharding_wrapper_in_runfiles_test",
        target_under_test = ":sharded_test_extended",
    )

    rust_test(
        name = "sharded_test_disabled",
        srcs = ["sharded_test.rs"],
        edition = "2021",
        experimental_enable_sharding = False,
    )

    sharding_disabled_test(
        name = "sharding_disabled_test",
        target_under_test = ":sharded_test_disabled",
    )

    rust_test(
        name = "sharded_integration_test",
        srcs = ["sharded_test.rs"],
        edition = "2021",
        experimental_enable_sharding = True,
        shard_count = 3,
    )

    sh_test(
        name = "test_sharding_wrapper_hashes_sorted_names",
        srcs = ["test_sharding_wrapper_hashes_sorted_names.sh"],
        args = [
            "$(location //rust/private:test_sharding_wrapper.sh)",
            "$(location :fake_libtest_binary.sh)",
        ],
        data = [
            ":fake_libtest_binary.sh",
            "//rust/private:test_sharding_wrapper.sh",
        ],
        target_compatible_with = select({
            "@platforms//os:windows": ["@platforms//:incompatible"],
            "//conditions:default": [],
        }),
    )

def test_sharding_test_suite(name):
    _test_sharding_targets()

    native.test_suite(
        name = name,
        tests = [
            ":sharding_enabled_test",
            ":sharding_wrapper_in_runfiles_test",
            ":sharding_disabled_test",
            ":test_sharding_wrapper_hashes_sorted_names",
            ":sharded_integration_test",
        ],
    )
