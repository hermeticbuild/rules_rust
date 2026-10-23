"""Normalized sources replace compiler inputs, but not the crate's source provider."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//rust:defs.bzl", "rust_common")

def _source_normalization_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    sources = target[rust_common.crate_info].srcs.to_list()
    asserts.true(env, all([source.is_source for source in sources]))
    normalizer = [action for action in target.actions if action.mnemonic == "RustNormalizeSources"][0]
    output = normalizer.outputs.to_list()[0]
    asserts.true(env, output.is_directory)
    for source in sources:
        asserts.true(env, source in normalizer.inputs.to_list())
    for mnemonic in ["Rustc", "RustcMetadata"]:
        action = [action for action in target.actions if action.mnemonic == mnemonic][0]
        inputs = action.inputs.to_list()
        asserts.true(env, output in inputs)
        for source in sources:
            asserts.false(env, source in inputs)
    return analysistest.end(env)

source_normalization_test = analysistest.make(
    _source_normalization_test_impl,
    config_settings = {str(Label("//rust/settings:pipelined_compilation")): True},
)
