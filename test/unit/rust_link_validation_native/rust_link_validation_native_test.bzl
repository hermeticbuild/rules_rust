"""Analysis tests for native (C/C++) Rust crate-instance link validation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")
load("//rust:defs.bzl", "rust_common", "rust_library", "rust_shared_library", "rust_static_library")
load("//rust:rust_link_validation.bzl", "rust_link_checked_cc_binary", "rust_link_checked_cc_shared_library", "rust_link_checked_cc_test")

_IDENTITY = "cargo:registry+https://index.crates.io/#dup@1.0.0"

def _closure_provider_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    closure = tut[rust_common.rust_link_closure_info]
    asserts.equals(env, ctx.attr.expect_linkage, closure.linkage)
    owners = []
    for identity in closure.crates.to_list():
        owners.append(str(identity.owner))
    expects = ctx.attr.expect_owners
    asserts.true(env, len(expects) > 0)
    for token in expects:
        present = False
        for owner in owners:
            if token in owner:
                present = True
                break
        asserts.true(env, present, "missing %s among %s" % (token, sorted(owners)))
    return analysistest.end(env)

closure_provider_test = analysistest.make(
    _closure_provider_test_impl,
    attrs = {
        "expect_linkage": attr.string(),
        "expect_owners": attr.string_list(),
    },
)

def _native_conflict_test():
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(
            env,
            "would link incompatible instances of the same Rust library",
        )
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

native_conflict_test = _native_conflict_test()

def _native_clean_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

native_clean_test = analysistest.make(_native_clean_test_impl)

def rust_link_validation_native_test_suite(name):
    """Creates the native-link validation analysis test suite.

    Args:
        name: Name of the generated test suite.
    """

    # Two classes of one logical identity, each wrapped in its own static lib.
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
    rust_static_library(
        name = "platform_static_one",
        srcs = ["lib.rs"],
        deps = [":class_one"],
        crate_name = "platform_static_one",
    )
    rust_static_library(
        name = "platform_static_two",
        srcs = ["lib.rs"],
        deps = [":class_two"],
        crate_name = "platform_static_two",
    )

    # ---------------- raw negative control ----------------
    # A raw cc_binary without the aspect/wrapper is not checked and must build.
    cc_binary(
        name = "raw_unchecked",
        srcs = ["main.cc"],
        deps = [":platform_static_one", ":platform_static_two"],
    )
    native_clean_test(
        name = "raw_unchecked_test",
        target_under_test = ":raw_unchecked",
    )

    # A test-only Rust static library for the testonly-propagation checks.
    rust_static_library(
        name = "testonly_static",
        srcs = ["lib.rs"],
        deps = [":class_one"],
        crate_name = "testonly_static",
        testonly = True,
    )

    # ---------------- checked conflict cases (fail) ----------------
    rust_link_checked_cc_binary(
        name = "checked_conflict",
        srcs = ["main.cc"],
        deps = [":platform_static_one", ":platform_static_two"],
        tags = ["manual"],
    )
    native_conflict_test(
        name = "checked_conflict_test",
        target_under_test = ":checked_conflict",
    )

    # Conflict remains when a cc_library sits between the binary and the static libs.
    cc_library(
        name = "native_mid_one",
        deps = [":platform_static_one"],
    )
    cc_library(
        name = "native_mid_two",
        deps = [":platform_static_two"],
    )
    rust_link_checked_cc_binary(
        name = "checked_transitive_conflict",
        srcs = ["main.cc"],
        deps = [":native_mid_one", ":native_mid_two"],
        tags = ["manual"],
    )
    native_conflict_test(
        name = "checked_transitive_conflict_test",
        target_under_test = ":checked_transitive_conflict",
    )

    # A checked shared library containing conflicting static closures fails.
    rust_link_checked_cc_shared_library(
        name = "checked_shared_conflict",
        deps = [":platform_static_one", ":platform_static_two"],
        tags = ["manual"],
    )
    native_conflict_test(
        name = "checked_shared_conflict_test",
        target_under_test = ":checked_shared_conflict",
    )

    # ---------------- checked allowed cases (pass) ----------------
    rust_link_checked_cc_binary(
        name = "checked_separate_one",
        srcs = ["main.cc"],
        deps = [":platform_static_one"],
    )
    rust_link_checked_cc_binary(
        name = "checked_separate_two",
        srcs = ["main.cc"],
        deps = [":platform_static_two"],
    )
    native_clean_test(
        name = "checked_separate_one_test",
        target_under_test = ":checked_separate_one",
    )
    native_clean_test(
        name = "checked_separate_two_test",
        target_under_test = ":checked_separate_two",
    )

    # The same instance reached through two native paths: pass (dedup by artifact).
    cc_library(
        name = "native_wrap",
        deps = [":platform_static_one"],
    )
    rust_link_checked_cc_binary(
        name = "checked_shared_path",
        srcs = ["main.cc"],
        deps = [":platform_static_one", ":native_wrap"],
    )
    native_clean_test(
        name = "checked_shared_path_test",
        target_under_test = ":checked_shared_path",
    )

    # Two separately valid shared libraries are independent link units: a checked
    # binary linking both is allowed even though they share the logical identity.
    rust_shared_library(
        name = "dyn_lib_one",
        srcs = ["lib.rs"],
        deps = [":class_one"],
        crate_name = "dyn_lib_one",
    )
    rust_shared_library(
        name = "dyn_lib_two",
        srcs = ["lib.rs"],
        deps = [":class_two"],
        crate_name = "dyn_lib_two",
    )
    rust_link_checked_cc_binary(
        name = "checked_two_dynamic",
        srcs = ["main.cc"],
        deps = [":dyn_lib_one", ":dyn_lib_two"],
    )
    native_clean_test(
        name = "checked_two_dynamic_test",
        target_under_test = ":checked_two_dynamic",
    )

    # Provider contract: static vs dynamic linkage + depset content (also
    # exercises RustCrateIdentityInfo depset hashability).
    rust_static_library(
        name = "contract_static",
        srcs = ["lib.rs"],
        deps = [":class_one"],
        crate_name = "contract_static",
    )
    closure_provider_test(
        name = "static_closure_provider_test",
        target_under_test = ":contract_static",
        expect_linkage = "static",
        expect_owners = ["class_one"],
    )
    rust_library(
        name = "native_bridge",
        srcs = ["lib.rs"],
        link_deps = [":native_mid_one"],
        crate_name = "native_bridge",
    )
    closure_provider_test(
        name = "native_bridge_closure_provider_test",
        target_under_test = ":native_bridge",
        expect_linkage = "static",
        expect_owners = ["class_one"],
    )
    closure_provider_test(
        name = "dynamic_closure_provider_test",
        target_under_test = ":dyn_lib_one",
        expect_linkage = "dynamic",
        expect_owners = ["class_one"],
    )

    rust_link_checked_cc_test(
        name = "checked_testonly_test",
        srcs = ["main.cc"],
        deps = [":testonly_static"],
    )
    native_clean_test(
        name = "checked_testonly_test_ok",
        target_under_test = ":checked_testonly_test",
    )

    # An explicitly test-only checked binary with a test-only Rust dep too.
    rust_link_checked_cc_binary(
        name = "checked_testonly_bin",
        srcs = ["main.cc"],
        deps = [":testonly_static"],
        testonly = True,
    )
    native_clean_test(
        name = "checked_testonly_bin_ok",
        target_under_test = ":checked_testonly_bin",
    )

    native.test_suite(
        name = name,
        tests = [
            ":checked_conflict_test",
            ":checked_separate_one_test",
            ":checked_separate_two_test",
            ":checked_shared_conflict_test",
            ":checked_shared_path_test",
            ":checked_testonly_bin_ok",
            ":checked_testonly_test_ok",
            ":checked_transitive_conflict_test",
            ":checked_two_dynamic_test",
            ":dynamic_closure_provider_test",
            ":native_bridge_closure_provider_test",
            ":raw_unchecked_test",
            ":static_closure_provider_test",
        ],
    )
