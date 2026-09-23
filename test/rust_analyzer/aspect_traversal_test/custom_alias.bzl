"""Alias-like rule for testing."""

load("@rules_rust//rust/private:providers.bzl", "CrateInfo", "DepInfo")

def _custom_alias_impl(ctx):
    actual = ctx.attr.actual
    return [actual[CrateInfo], actual[DepInfo]]

custom_alias = rule(
    implementation = _custom_alias_impl,
    attrs = {
        "actual": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
    provides = [CrateInfo, DepInfo],
)
