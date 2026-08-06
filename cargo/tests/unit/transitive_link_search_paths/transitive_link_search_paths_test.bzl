"""Unittests for rust rules."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//cargo:defs.bzl", "cargo_build_script")
load("//rust:defs.bzl", "rust_binary", "rust_common", "rust_library", "rust_proc_macro")
load(
    "//test/unit:common.bzl",
    "assert_action_mnemonic",
    "assert_list_contains",
    "assert_list_contains_adjacent_elements",
    "assert_list_contains_adjacent_elements_not",
)

def _transitive_link_search_paths_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    link_search_path_files = tut[rust_common.dep_info].link_search_path_files.to_list()
    link_search_path_basenames = [f.basename for f in link_search_path_files]

    # Checks that this contains the dep build script, but not the build script
    # of the dep of the proc_macro.
    asserts.equals(env, link_search_path_basenames, ["dep_build_script.linksearchpaths"])

    action = tut.actions[0]
    assert_action_mnemonic(env, action, "Rustc")
    archive = tut[DefaultInfo].files.to_list()[0]
    checked_output = archive
    if any([arg.endswith("-windows-msvc") for arg in action.argv]):
        object_files = [
            output
            for output in action.outputs.to_list()
            if output.extension in ("o", "obj")
        ]
        asserts.equals(env, 1, len(object_files))
        checked_output = object_files[0]
        assert_list_contains_adjacent_elements_not(env, action.argv, [
            "--check-output-for-working-dir",
            archive.path,
        ])

    assert_list_contains_adjacent_elements(env, action.argv, [
        "--check-output-for-working-dir",
        checked_output.path,
    ])

    return analysistest.end(env)

transitive_link_search_paths_test = analysistest.make(_transitive_link_search_paths_test_impl)

def _transitive_out_dir_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    action = tut.actions[0]
    assert_action_mnemonic(env, action, "Rustc")
    inputs = action.inputs.to_list()
    input_basenames = [f.basename for f in inputs]
    assert_list_contains(env, input_basenames, "dep_build_script.out_dir")

    return analysistest.end(env)

transitive_out_dir_test = analysistest.make(_transitive_out_dir_test_impl)

def _transitive_link_search_paths_test():
    cargo_build_script(
        name = "proc_macro_build_script",
        srcs = ["proc_macro_build.rs"],
        edition = "2018",
    )

    rust_proc_macro(
        name = "proc_macro",
        srcs = ["proc_macro.rs"],
        edition = "2018",
        deps = [":proc_macro_build_script"],
    )

    cargo_build_script(
        name = "dep_build_script",
        srcs = ["dep_build.rs"],
        edition = "2018",
    )

    rust_library(
        name = "dep",
        srcs = ["dep.rs"],
        edition = "2018",
        proc_macro_deps = [":proc_macro"],
        deps = [":dep_build_script"],
    )

    rust_binary(
        name = "bin",
        srcs = ["bin.rs"],
        edition = "2018",
        deps = [":dep"],
    )

    transitive_link_search_paths_test(
        name = "transitive_link_search_paths_test",
        target_under_test = ":dep",
    )

    transitive_out_dir_test(
        name = "transitive_out_dir_test",
        target_under_test = ":bin",
    )

def transitive_link_search_paths_test_suite(name):
    """Entry-point macro called from the BUILD file.

    Args:
        name: Name of the macro.
    """
    _transitive_link_search_paths_test()

    native.test_suite(
        name = name,
        tests = [
            ":transitive_link_search_paths_test",
            ":transitive_out_dir_test",
        ],
    )
