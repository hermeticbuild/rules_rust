"""Unittests for rust rules."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_cc//cc:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load(
    "//rust:defs.bzl",
    "rust_binary",
    "rust_library",
    "rust_shared_library",
    "rust_static_library",
    "rust_test",
)

def _check_runfiles_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    runfiles = tut[DefaultInfo].default_runfiles.files.to_list()

    asserts.true(env, _is_in_runfiles("libbar.so", runfiles))

    # cc_libraries put shared libs to data runfiles even when linking statically
    # and there is a static library alternative. We must be careful not to put
    # these shared libs to default runfiles.
    asserts.false(env, _is_in_runfiles("libtest_Sunit_Scheck_Urunfiles_Slibcc_Ulib.so", runfiles))

    return analysistest.end(env)

def _is_in_runfiles(name, runfiles):
    for file in runfiles:
        if file.basename == name:
            return True
    return False

check_runfiles_test = analysistest.make(_check_runfiles_test_impl)

def _check_imported_dylib_runfiles_test_impl(ctx):
    """A target that loads an imported dylib must carry it in its runfiles.

    Unlike a cc_binary(linkshared = True), a cc_import contributes no runfiles
    of its own, so the dylib reaches the consumer only through the dynamic
    library collection in rustc.bzl. If that collection skips the consumer, the
    executable still links and still runs locally -- its RUNPATH points into the
    execroot _solib_* directory, which happens to sit beside it -- and then
    fails at load time anywhere the input tree is exactly the declared runfiles,
    i.e. under remote execution.
    """
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    runfiles = tut[DefaultInfo].default_runfiles.files.to_list()

    asserts.true(
        env,
        _is_in_runfiles("libimported.so", runfiles),
        "libimported.so is missing from runfiles; the target would fail to load it under remote execution",
    )

    return analysistest.end(env)

check_imported_dylib_runfiles_test = analysistest.make(_check_imported_dylib_runfiles_test_impl)

def _check_runfiles_test():
    cc_library(
        name = "cc_lib",
        srcs = ["bar.cc"],
    )
    rust_library(
        name = "foo_lib",
        srcs = ["foo.rs"],
        edition = "2018",
        deps = [":libbar.so", ":cc_lib"],
    )

    rust_binary(
        name = "foo_bin",
        srcs = ["foo_main.rs"],
        edition = "2018",
        deps = [":libbar.so"],
    )

    rust_shared_library(
        name = "foo_dylib",
        srcs = ["foo.rs"],
        edition = "2018",
        deps = [":libbar.so"],
    )

    rust_static_library(
        name = "foo_static",
        srcs = ["foo.rs"],
        edition = "2018",
        deps = [":libbar.so"],
    )

    # buildifier: disable=native-cc
    cc_binary(
        name = "libbar.so",
        srcs = ["bar.cc"],
        linkshared = True,
    )

    check_runfiles_test(
        name = "check_runfiles_lib_test",
        target_under_test = ":foo_lib",
    )

    check_runfiles_test(
        name = "check_runfiles_bin_test",
        target_under_test = ":foo_bin",
    )

    check_runfiles_test(
        name = "check_runfiles_dylib_test",
        target_under_test = ":foo_dylib",
    )

    check_runfiles_test(
        name = "check_runfiles_static_test",
        target_under_test = ":foo_static",
    )

def _check_imported_dylib_runfiles_test():
    # buildifier: disable=native-cc
    cc_binary(
        name = "libimported.so",
        srcs = ["bar.cc"],
        linkshared = True,
    )

    # A cc_import, unlike the cc_binary above, exposes the dylib only through
    # its CcInfo linking context -- its own runfiles are empty.
    # Restricted to Linux/macOS: on Windows a cc_import of a shared library
    # also needs an interface_library (.lib) to link against, which this
    # minimal fixture does not produce. The runfiles behaviour under test is
    # platform-independent, so skipping Windows keeps the fixture simple.
    cc_import(
        name = "imported_cc_lib",
        shared_library = ":libimported.so",
    )

    _non_windows = select({
        "@platforms//os:windows": ["@platforms//:incompatible"],
        "//conditions:default": [],
    })

    rust_library(
        name = "imported_dylib_lib",
        srcs = ["foo.rs"],
        edition = "2018",
        deps = [":imported_cc_lib"],
        target_compatible_with = _non_windows,
    )

    rust_binary(
        name = "imported_dylib_bin",
        srcs = ["foo_main.rs"],
        edition = "2018",
        deps = [":imported_cc_lib"],
        target_compatible_with = _non_windows,
    )

    # Reaches the dylib through `crate`, not `deps`.
    rust_test(
        name = "imported_dylib_test",
        crate = ":imported_dylib_lib",
        target_compatible_with = _non_windows,
    )

    check_imported_dylib_runfiles_test(
        name = "check_imported_dylib_runfiles_bin_test",
        target_under_test = ":imported_dylib_bin",
        target_compatible_with = _non_windows,
    )

    check_imported_dylib_runfiles_test(
        name = "check_imported_dylib_runfiles_test_test",
        target_under_test = ":imported_dylib_test",
        target_compatible_with = _non_windows,
    )

def check_runfiles_test_suite(name):
    """Entry-point macro called from the BUILD file.

    Args:
        name: Name of the macro.
    """
    _check_runfiles_test()
    _check_imported_dylib_runfiles_test()

    native.test_suite(
        name = name,
        tests = [
            ":check_runfiles_lib_test",
            ":check_runfiles_bin_test",
            ":check_runfiles_dylib_test",
            ":check_runfiles_static_test",
            ":check_imported_dylib_runfiles_bin_test",
            ":check_imported_dylib_runfiles_test_test",
        ],
    )
