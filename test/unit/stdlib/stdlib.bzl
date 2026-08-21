"""Unittest to verify contents and ordering of rust stdlib in rust_library() CcInfo"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//rust:defs.bzl", "rust_library")

def _categorize_library(name):
    """Given an rlib name, guess if it's std, core, or alloc."""
    if "std" in name:
        return "std"
    if "core" in name:
        return "core"
    if "alloc" in name:
        return "alloc"
    if "compiler_builtins" in name:
        return "compiler_builtins"
    return "other"

def _dedup_preserving_order(list):
    """Given a list, deduplicate its elements preserving order."""
    r = []
    seen = {}
    for e in list:
        if e in seen:
            continue
        seen[e] = 1
        r.append(e)
    return r

def _stdlibs(tut):
    """Given a target, return the list of its standard rust libraries."""
    libs = [
        lib.static_library
        for li in tut[CcInfo].linking_context.linker_inputs.to_list()
        for lib in li.libraries
    ]
    stdlibs = [lib for lib in libs if (lib and tut.label.name not in lib.basename)]
    return stdlibs

def _libstd_ordering_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    stdlib_categories = [_categorize_library(lib.basename) for lib in _stdlibs(tut)]
    set_to_check = _dedup_preserving_order([lib for lib in stdlib_categories if lib != "other"])
    asserts.equals(env, ["std", "core", "compiler_builtins", "alloc"], set_to_check)
    return analysistest.end(env)

libstd_ordering_test = analysistest.make(_libstd_ordering_test_impl)

def _libstd_panic_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    stdlibs = _stdlibs(tut)
    has_panic_unwind = bool([lib for lib in stdlibs if "panic_unwind" in lib.basename])
    has_panic_abort = bool([lib for lib in stdlibs if "panic_abort" in lib.basename])
    asserts.equals(env, ctx.attr.expected_panic_strategy == "unwind", has_panic_unwind)
    asserts.equals(env, ctx.attr.expected_panic_strategy == "abort", has_panic_abort)

    return analysistest.end(env)

libstd_panic_test = analysistest.make(
    _libstd_panic_test_impl,
    attrs = {"expected_panic_strategy": attr.string(mandatory = True)},
)

libstd_abort_panic_test = analysistest.make(
    _libstd_panic_test_impl,
    attrs = {"expected_panic_strategy": attr.string(mandatory = True)},
    config_settings = {
        str(Label("//rust/settings:cc_common_link_panic_strategy")): "abort",
        str(Label("//rust/settings:experimental_use_cc_common_link")): True,
    },
)

libstd_disabled_cc_common_panic_setting_test = analysistest.make(
    _libstd_panic_test_impl,
    attrs = {"expected_panic_strategy": attr.string(mandatory = True)},
    config_settings = {
        str(Label("//rust/settings:cc_common_link_panic_strategy")): "abort",
        str(Label("//rust/settings:experimental_use_cc_common_link")): False,
    },
)

def _native_dep_test():
    rust_library(
        name = "some_rlib",
        srcs = ["some_rlib.rs"],
        edition = "2018",
    )

    rust_library(
        name = "some_abort_rlib",
        srcs = ["some_rlib.rs"],
        edition = "2018",
        deps = [":some_rlib"],
    )

    rust_library(
        name = "some_transitive_abort_rlib",
        srcs = ["some_rlib.rs"],
        edition = "2018",
        deps = [":some_abort_rlib"],
    )

    libstd_ordering_test(
        name = "libstd_ordering_test",
        target_under_test = ":some_rlib",
    )

    libstd_panic_test(
        name = "libstd_panic_test",
        target_under_test = ":some_rlib",
        expected_panic_strategy = "unwind",
    )

    libstd_disabled_cc_common_panic_setting_test(
        name = "libstd_disabled_cc_common_panic_setting_test",
        target_under_test = ":some_rlib",
        expected_panic_strategy = "unwind",
    )

    libstd_abort_panic_test(
        name = "libstd_abort_panic_test",
        target_under_test = ":some_abort_rlib",
        expected_panic_strategy = "abort",
    )

    libstd_abort_panic_test(
        name = "libstd_transitive_abort_panic_test",
        target_under_test = ":some_transitive_abort_rlib",
        expected_panic_strategy = "abort",
    )

def stdlib_suite(name):
    """Entry-point macro called from the BUILD file.

    Args:
        name: Name of the macro.
    """
    _native_dep_test()

    native.test_suite(
        name = name,
        tests = [
            ":libstd_ordering_test",
            ":libstd_panic_test",
            ":libstd_disabled_cc_common_panic_setting_test",
            ":libstd_abort_panic_test",
            ":libstd_transitive_abort_panic_test",
        ],
    )
