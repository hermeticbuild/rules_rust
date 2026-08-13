# Copyright 2021 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Native (C/C++) link validation for Rust crate instances.

Rust link rules validate their target-runtime closure intrinsically (see
`rust/private/rustc.bzl`). An internal aspect preserves identity metadata when
static Rust libraries reach a Rust target through ordinary `cc_library` `deps`
or `implementation_deps`. A native final link -- e.g. a `cc_binary` linking two
`rust_static_library`s -- is outside that intrinsic check and is **not**
validated by default. This module is the opt-in affordance for native links:

* `rust_link_validation_aspect`: applies the same per-link-unit invariant to
  native link units reached transitively. Enable it with
  `--aspects=@rules_rust//rust:rust_link_validation.bzl%rust_link_validation_aspect`.
* `rust_link_checked_cc_binary` / `rust_link_checked_cc_test` /
  `rust_link_checked_cc_shared_library`: paved-path wrappers that force the
  check during analysis without adding linker inputs.

Because plain `cc_binary`/`cc_test`/`cc_shared_library` are never checked unless
one of these is applied, a C++ link that embeds duplicate Rust instances will
still build silently by default. Use the wrappers or the command-line aspect
wherever a native link may absorb Rust static crates.

The aspect can follow declared `deps` and `implementation_deps`. It cannot
recover identity after a custom rule discards the dependency graph, or from raw
archives supplied through `srcs`, `linkopts`, linker scripts, or other
untraversed attributes. Prebuilt Rust archives also remain invisible unless a
rule attaches identity metadata to them.
"""

load("@rules_cc//cc:defs.bzl", _cc_binary = "cc_binary", _cc_shared_library = "cc_shared_library", _cc_test = "cc_test")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//rust/private:rust_crate_identity.bzl", "validate_crate_identity_closure")
load("//rust/private:rust_link_validation.bzl", _RustLinkAggregationInfo = "RustLinkAggregationInfo", _native_rust_link_validation_aspect = "native_rust_link_validation_aspect")

rust_link_validation_aspect = _native_rust_link_validation_aspect

def _rust_link_checker_impl(ctx):
    """Validates the Rust identity closure of the forwarded native deps."""
    crates = []
    for dep in ctx.attr.deps:
        if _RustLinkAggregationInfo in dep:
            crates.append(dep[_RustLinkAggregationInfo].crates)

    identities = []
    for closure in crates:
        identities.extend(closure.to_list())

    validate_crate_identity_closure(ctx.label, identities)

    return [
        DefaultInfo(),
        # Empty CcInfo: forces analysis of the checker (and its aspect) when the
        # real native target depends on it, without adding any linker inputs.
        CcInfo(
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([]),
            ),
        ),
    ]

_rust_link_checker = rule(
    implementation = _rust_link_checker_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "Forwarded native deps the aspect should aggregate and validate.",
            aspects = [rust_link_validation_aspect],
        ),
    },
    doc = "Analysis-only Rust crate-instance validator for a native link.",
)

def rust_link_checked_cc_binary(name, deps = [], **kwargs):
    """A `cc_binary` whose Rust identity closure is validated during analysis."""
    _rust_link_checked(_cc_binary, name, deps, **kwargs)

def rust_link_checked_cc_test(name, deps = [], **kwargs):
    """A `cc_test` whose Rust identity closure is validated during analysis."""
    _rust_link_checked(_cc_test, name, deps, **kwargs)

def rust_link_checked_cc_shared_library(name, deps = [], **kwargs):
    """A `cc_shared_library` whose Rust identity closure is validated during analysis."""
    _rust_link_checked(_cc_shared_library, name, deps, **kwargs)

def _rust_link_checked(cc_rule, name, deps, **kwargs):
    checker = "_" + name + "_crate_link_check"
    _rust_link_checker(
        name = checker,
        deps = deps,
        tags = ["manual"],
    )

    # Forward the original deps plus the analysis-only checker. The checker
    # contributes an empty CcInfo, so it forces the validator to run without
    # altering the link inputs.
    cc_rule(
        name = name,
        deps = deps + [":" + checker],
        **kwargs
    )
