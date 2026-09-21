"""Unittests for rust rules."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//rust:defs.bzl", "rust_binary", "rust_library", "rust_proc_macro", "rust_test")

_TARGETS = [
    struct(name = "bin", rule = rust_binary, srcs = ["bin.rs"]),
    struct(name = "lib", rule = rust_library, srcs = ["lib.rs"]),
    struct(name = "macro", rule = rust_proc_macro, srcs = ["macro.rs"]),
    struct(name = "unit", rule = rust_test, srcs = ["unit.rs"]),
]

def _metadata_output_groups_present_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    output_groups = tut[OutputGroupInfo]
    build_metadata = output_groups.build_metadata.to_list()
    rustc_rmeta_output = output_groups.rustc_rmeta_output.to_list()

    asserts.equals(env, 1, len(build_metadata), "Expected 1 build_metadata file")
    asserts.true(
        env,
        build_metadata[0].basename.endswith("_meta.rlib"),
        "Expected %s to end with _meta.rlib" % build_metadata[0],
    )

    asserts.equals(env, 1, len(rustc_rmeta_output), "Expected 1 rustc_rmeta_output file")
    asserts.true(
        env,
        rustc_rmeta_output[0].basename.endswith(".rustc-output"),
        "Expected %s to end with .rustc-output" % rustc_rmeta_output[0],
    )

    return analysistest.end(env)

def _metadata_output_groups_missing_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    output_groups = tut[OutputGroupInfo]
    asserts.false(env, hasattr(output_groups, "build_metadata"), "Expected no build_metadata output group")
    asserts.false(env, hasattr(output_groups, "rustc_rmeta_output"), "Expected no rustc_rmeta_output output group")

    return analysistest.end(env)

def _collect_metadata_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        target[OutputGroupInfo].build_metadata
        for target in ctx.attr.targets
    ]))]

_collect_metadata = rule(
    implementation = _collect_metadata_impl,
    attrs = {"targets": attr.label_list()},
)

def _metadata_names_test_impl(ctx):
    env = analysistest.begin(ctx)
    metadata = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.equals(env, 4, len(metadata), "Each binary and test must have its own metadata output")
    return analysistest.end(env)

_metadata_names_test = analysistest.make(
    _metadata_names_test_impl,
    config_settings = {
        str(Label("//rust/settings:always_enable_metadata_output_groups")): True,
    },
)

def _metadata_names_test_targets():
    targets = []
    for suffix in ("a", "b"):
        rust_binary(
            name = "same_name_binary_" + suffix,
            crate_name = "shared_binary",
            srcs = ["bin.rs"],
            edition = "2021",
            tags = ["manual"],
        )
        rust_test(
            name = "same_name_unit_" + suffix,
            crate_name = "shared_unit",
            srcs = ["unit.rs"],
            edition = "2021",
            tags = ["manual"],
        )
        targets.extend([
            ":same_name_binary_" + suffix,
            ":same_name_unit_" + suffix,
        ])
    _collect_metadata(
        name = "same_name_metadata",
        targets = targets,
        testonly = True,
        tags = ["manual"],
    )
    _metadata_names_test(
        name = "metadata_names_test",
        target_under_test = ":same_name_metadata",
    )
    return [":metadata_names_test"]

metadata_output_groups_present_test = analysistest.make(
    _metadata_output_groups_present_test_impl,
    config_settings = {
        str(Label("//rust/settings:always_enable_metadata_output_groups")): True,
        str(Label("//rust/settings:rustc_output_diagnostics")): True,
    },
)

metadata_output_groups_missing_test = analysistest.make(
    _metadata_output_groups_missing_test_impl,
)

def _output_groups_test(*, always_enable, suffix, present_test = None):
    test = present_test if always_enable else metadata_output_groups_missing_test

    for target in _TARGETS:
        target.rule(
            name = target.name + suffix,
            srcs = target.srcs,
            edition = "2021",
        )

        test(
            name = target.name + "_test" + suffix,
            target_under_test = ":" + target.name + suffix,
        )

    return [
        ":" + target.name + "_test" + suffix
        for target in _TARGETS
    ]

def metadata_output_groups_test_suite(name):
    """Entry-point macro called from the BUILD file.

    Args:
        name: Name of the macro.
    """
    tests = []
    tests.extend(_output_groups_test(
        always_enable = True,
        suffix = "_with_metadata",
        present_test = metadata_output_groups_present_test,
    ))
    tests.extend(_output_groups_test(
        always_enable = False,
        suffix = "_without_metadata",
    ))
    tests.extend(_metadata_names_test_targets())

    native.test_suite(
        name = name,
        tests = tests,
    )
