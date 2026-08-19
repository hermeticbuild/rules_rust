"""Analysis tests for rustc_env_paths validation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//rust:defs.bzl", "rust_library")

def _expect_failure(ctx, message):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, message)
    return analysistest.end(env)

rustc_env_paths_conflict_test = analysistest.make(
    lambda ctx: _expect_failure(ctx, "rustc_env_paths environment variable CONFLICT conflicts with another rustc environment variable"),
    expect_failure = True,
)

rustc_env_paths_duplicate_test = analysistest.make(
    lambda ctx: _expect_failure(ctx, "rustc_env_paths contains multiple files for environment variable DUPLICATE"),
    expect_failure = True,
)

rustc_env_paths_multiple_outputs_test = analysistest.make(
    lambda ctx: _expect_failure(ctx, "must produce exactly one file, got 2"),
    expect_failure = True,
)

def rustc_env_paths_test_suite(name):
    """Defines rustc_env_paths validation tests.

    Args:
        name: The test suite name.
    """
    write_file(
        name = "first_file",
        out = "first.txt",
        content = ["first"],
    )
    write_file(
        name = "second_file",
        out = "second.txt",
        content = ["second"],
    )
    native.genrule(
        name = "multiple_files",
        outs = ["multiple_a.txt", "multiple_b.txt"],
        cmd = "touch $(OUTS)",
    )

    rust_library(
        name = "conflicting_env",
        srcs = ["lib.rs"],
        edition = "2018",
        rustc_env = {"CONFLICT": "value"},
        rustc_env_paths = {":first_file": "CONFLICT"},
        tags = ["manual"],
    )
    rust_library(
        name = "duplicate_env",
        srcs = ["lib.rs"],
        edition = "2018",
        rustc_env_paths = {
            ":first_file": "DUPLICATE",
            ":second_file": "DUPLICATE",
        },
        tags = ["manual"],
    )
    rust_library(
        name = "multiple_outputs",
        srcs = ["lib.rs"],
        edition = "2018",
        rustc_env_paths = {":multiple_files": "MULTIPLE"},
        tags = ["manual"],
    )

    rustc_env_paths_conflict_test(
        name = "rustc_env_paths_conflict_test",
        target_under_test = ":conflicting_env",
    )
    rustc_env_paths_duplicate_test(
        name = "rustc_env_paths_duplicate_test",
        target_under_test = ":duplicate_env",
    )
    rustc_env_paths_multiple_outputs_test(
        name = "rustc_env_paths_multiple_outputs_test",
        target_under_test = ":multiple_outputs",
    )

    native.test_suite(
        name = name,
        tests = [
            ":rustc_env_paths_conflict_test",
            ":rustc_env_paths_duplicate_test",
            ":rustc_env_paths_multiple_outputs_test",
        ],
    )
