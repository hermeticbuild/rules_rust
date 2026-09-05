"""Expose tinyjson from the process wrapper's bootstrap configuration."""

load("//rust:defs.bzl", "rust_common")

def _bootstrap_tinyjson_impl(ctx):
    crates = ctx.attr.process_wrapper[rust_common.dep_info].transitive_crates.to_list()
    tinyjson = [crate.output for crate in crates if crate.name == "tinyjson"]
    if len(tinyjson) != 1:
        fail("Expected one bootstrap tinyjson output, got %s" % tinyjson)
    return [DefaultInfo(files = depset(tinyjson))]

bootstrap_tinyjson = rule(
    implementation = _bootstrap_tinyjson_impl,
    attrs = {
        "process_wrapper": attr.label(
            cfg = "exec",
            default = "//util/process_wrapper:process_wrapper",
            providers = [rust_common.dep_info],
        ),
    },
)
