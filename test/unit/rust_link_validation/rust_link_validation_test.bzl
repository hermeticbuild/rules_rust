"""Analysis tests for the intrinsic Rust crate-instance link validation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("//rust:defs.bzl", "rust_binary", "rust_common", "rust_library", "rust_proc_macro", "rust_shared_library", "rust_static_library", "rust_test")

_IDENTITY = "cargo:registry+https://index.crates.io/#dup@1.0.0"

def _conflict_test():
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(
            env,
            "would link incompatible instances of the same Rust library",
        )
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

link_conflict_test = _conflict_test()

def _clean_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

link_clean_test = analysistest.make(_clean_test_impl)

def _identity_record_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    crate_info = tut[rust_common.crate_info]
    identity = crate_info.crate_identity
    asserts.true(env, identity != None)
    asserts.equals(env, _IDENTITY, identity.logical_id)
    asserts.equals(env, crate_info.output, identity.crate_instance)
    return analysistest.end(env)

identity_record_test = analysistest.make(_identity_record_test_impl)

def _no_identity_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    crate_info = tut[rust_common.crate_info]
    asserts.equals(env, None, crate_info.crate_identity)
    return analysistest.end(env)

no_identity_test = analysistest.make(_no_identity_test_impl)

def rust_link_validation_test_suite(name):
    """Creates the intrinsic Rust link-validation analysis test suite.

    Args:
        name: Name of the generated test suite.
    """
    rust_library(
        name = "class_one",
        srcs = ["lib.rs"],
        crate_identity = _IDENTITY,
        crate_name = "dup",
    )
    rust_library(
        name = "class_two",
        srcs = ["lib.rs"],
        crate_identity = _IDENTITY,
        crate_name = "dup",
    )
    rust_library(
        name = "plain_lib",
        srcs = ["lib.rs"],
        crate_name = "plain_lib",
    )
    rust_library(
        name = "other_identity",
        srcs = ["lib.rs"],
        crate_identity = "cargo:other@1.0.0",
        crate_name = "other_identity",
    )
    rust_library(
        name = "transitive_class_one",
        srcs = ["lib.rs"],
        deps = [":class_one"],
        crate_name = "transitive_class_one",
    )

    # ---------------- pass: identity sanity ----------------
    identity_record_test(
        name = "identity_record_test",
        target_under_test = ":class_one",
    )
    no_identity_test(
        name = "plain_lib_has_no_identity_test",
        target_under_test = ":plain_lib",
    )

    # ---------------- pass: single instance ----------------
    rust_binary(
        name = "single_identity_bin",
        srcs = ["main.rs"],
        deps = [":class_one"],
    )
    link_clean_test(
        name = "single_identity_bin_test",
        target_under_test = ":single_identity_bin",
    )

    # Different logical identities in one binary: pass.
    rust_binary(
        name = "different_identities_bin",
        srcs = ["main.rs"],
        deps = [":class_one", ":other_identity"],
    )
    link_clean_test(
        name = "different_identities_bin_test",
        target_under_test = ":different_identities_bin",
    )

    # Same instance reached through a parallel transitive path: pass (dedup by artifact).
    rust_binary(
        name = "shared_path_bin",
        srcs = ["main.rs"],
        deps = [":class_one", ":transitive_class_one"],
    )
    link_clean_test(
        name = "shared_path_bin_test",
        target_under_test = ":shared_path_bin",
    )

    # Two incompatible instances used by separate binaries: pass.
    rust_binary(
        name = "separate_bin_one",
        srcs = ["main.rs"],
        deps = [":class_one"],
    )
    rust_binary(
        name = "separate_bin_two",
        srcs = ["main.rs"],
        deps = [":class_two"],
    )
    link_clean_test(
        name = "separate_bin_one_test",
        target_under_test = ":separate_bin_one",
    )
    link_clean_test(
        name = "separate_bin_two_test",
        target_under_test = ":separate_bin_two",
    )

    # Proc-macro host closure is not folded into the target-runtime closure:
    # a proc macro with the same logical identity as a runtime lib must pass.
    rust_proc_macro(
        name = "same_identity_proc_macro",
        srcs = ["proc.rs"],
        crate_identity = _IDENTITY,
        crate_name = "same_identity_proc_macro",
    )
    rust_binary(
        name = "proc_macro_isolation_bin",
        srcs = ["main.rs"],
        deps = [":class_one"],
        proc_macro_deps = [":same_identity_proc_macro"],
    )
    link_clean_test(
        name = "proc_macro_isolation_bin_test",
        target_under_test = ":proc_macro_isolation_bin",
    )

    # Rust identities remain visible when static Rust libraries travel through
    # ordinary native dependency edges on their way to a Rust terminal link.
    rust_static_library(
        name = "hidden_static_one",
        srcs = ["lib.rs"],
        deps = [":class_one"],
        crate_name = "hidden_static_one",
    )
    rust_static_library(
        name = "hidden_static_two",
        srcs = ["lib.rs"],
        deps = [":class_two"],
        crate_name = "hidden_static_two",
    )
    cc_library(
        name = "native_hidden_one",
        deps = [":hidden_static_one"],
    )
    cc_library(
        name = "native_hidden_two",
        deps = [":hidden_static_two"],
    )
    rust_binary(
        name = "native_hidden_same_instance_bin",
        srcs = ["main.rs"],
        link_deps = [
            ":hidden_static_one",
            ":native_hidden_one",
        ],
    )
    link_clean_test(
        name = "native_hidden_same_instance_bin_test",
        target_under_test = ":native_hidden_same_instance_bin",
    )

    # ---------------- fail: two instances in one link unit ----------------
    rust_binary(
        name = "direct_conflict_bin",
        srcs = ["main.rs"],
        deps = [":class_one", ":class_two"],
        tags = ["manual"],
    )
    link_conflict_test(
        name = "direct_conflict_bin_test",
        target_under_test = ":direct_conflict_bin",
    )

    rust_binary(
        name = "transitive_conflict_bin",
        srcs = ["main.rs"],
        deps = [":class_two", ":transitive_class_one"],
        tags = ["manual"],
    )
    link_conflict_test(
        name = "transitive_conflict_bin_test",
        target_under_test = ":transitive_conflict_bin",
    )

    rust_binary(
        name = "native_hidden_conflict_bin",
        srcs = ["main.rs"],
        link_deps = [
            ":native_hidden_one",
            ":native_hidden_two",
        ],
        tags = ["manual"],
    )
    link_conflict_test(
        name = "native_hidden_conflict_bin_test",
        target_under_test = ":native_hidden_conflict_bin",
    )

    rust_static_library(
        name = "staticlib_conflict",
        srcs = ["lib.rs"],
        deps = [":class_one", ":class_two"],
        tags = ["manual"],
    )
    link_conflict_test(
        name = "staticlib_conflict_test",
        target_under_test = ":staticlib_conflict",
    )

    rust_shared_library(
        name = "cdylib_conflict",
        srcs = ["lib.rs"],
        deps = [":class_one", ":class_two"],
        tags = ["manual"],
    )
    link_conflict_test(
        name = "cdylib_conflict_test",
        target_under_test = ":cdylib_conflict",
    )

    rust_proc_macro(
        name = "proc_macro_conflict",
        srcs = ["proc.rs"],
        deps = [":class_one", ":class_two"],
        tags = ["manual"],
    )
    link_conflict_test(
        name = "proc_macro_conflict_test",
        target_under_test = ":proc_macro_conflict",
    )

    rust_test(
        name = "test_conflict",
        srcs = ["lib.rs"],
        deps = [":class_one", ":class_two"],
        tags = ["manual"],
    )
    link_conflict_test(
        name = "test_conflict_test",
        target_under_test = ":test_conflict",
    )

    native.test_suite(
        name = name,
        tests = [
            ":cdylib_conflict_test",
            ":direct_conflict_bin_test",
            ":different_identities_bin_test",
            ":identity_record_test",
            ":native_hidden_conflict_bin_test",
            ":native_hidden_same_instance_bin_test",
            ":plain_lib_has_no_identity_test",
            ":proc_macro_conflict_test",
            ":proc_macro_isolation_bin_test",
            ":separate_bin_one_test",
            ":separate_bin_two_test",
            ":shared_path_bin_test",
            ":single_identity_bin_test",
            ":staticlib_conflict_test",
            ":test_conflict_test",
            ":transitive_conflict_bin_test",
        ],
    )
