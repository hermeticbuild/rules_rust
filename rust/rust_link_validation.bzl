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

Rust link rules validate their own target-runtime closure intrinsically (see
`rust/private/rustc.bzl`). A native final link -- e.g. a `cc_binary` linking two
`rust_static_library`s -- is outside that intrinsic check. This module supplies:

* `rust_link_validation_aspect`: applies the same per-link-unit invariant to
  native link units reached transitively. Enable it with
  `--aspects=@rules_rust//rust:rust_link_validation.bzl%rust_link_validation_aspect`.
* `rust_link_checked_cc_binary` / `rust_link_checked_cc_test` /
  `rust_link_checked_cc_shared_library`: paved-path wrappers that force the
  check during analysis without adding linker inputs.
"""

load("@rules_cc//cc:defs.bzl", _cc_binary = "cc_binary", _cc_shared_library = "cc_shared_library", _cc_test = "cc_test")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//rust/private:providers.bzl", "RustLinkClosureInfo")
load("//rust/private:rust_crate_identity.bzl", "validate_crate_identity_closure")

# Private aggregation provider returned by the aspect. It is distinct from
# RustLinkClosureInfo because Bazel does not allow an aspect and a target rule
# to return the same provider type, and the aspect needs to carry its result
# along the native shadow graph.
RustLinkAggregationInfo = provider(
    doc = "Aggregates static Rust identity closures along native dependency edges.",
    fields = {
        "crates": "depset[RustCrateIdentityInfo]: Static Rust identity closure reached so far.",
    },
)

# Native dependency attributes the aspect traverses. Only these have the aspect
# applied via `attr_aspects`, so only these can contribute aggregation results.
_NATIVE_DEP_ATTRS = ["deps", "implementation_deps"]

# Native link-unit rule kinds where the aggregated closure is finalized and the
# invariant is enforced.
_NATIVE_LINK_UNIT_KINDS = ("cc_binary", "cc_test", "cc_shared_library")

def _rust_link_validation_aspect_impl(target, ctx):
    """Propagates static Rust identity closures across native dep edges.

    A target that exposes RustLinkClosureInfo is a Rust boundary: its closure is
    already complete and authoritative, so it is a leaf of this shadow graph.
    We never descend into a Rust target's own `deps` -- doing so would pull a
    dynamic library's internal crates out of its private link boundary
    (observed via cquery traces) and double-count static ones.
    """
    if RustLinkClosureInfo in target:
        closure = target[RustLinkClosureInfo]
        if closure.linkage != "static":
            # Dynamic boundary: opaque. Contributes nothing and stops here.
            return []
        return [
            RustLinkAggregationInfo(crates = closure.crates),
        ]

    crates = []
    for attr_name in _NATIVE_DEP_ATTRS:
        if not hasattr(ctx.rule.attr, attr_name):
            continue
        for dep in getattr(ctx.rule.attr, attr_name):
            if RustLinkAggregationInfo in dep:
                crates.append(dep[RustLinkAggregationInfo].crates)

    if not crates:
        return []

    aggregation = RustLinkAggregationInfo(crates = depset(transitive = crates))

    if ctx.rule.kind in _NATIVE_LINK_UNIT_KINDS:
        validate_crate_identity_closure(ctx.label, aggregation.crates.to_list())

    return [aggregation]

rust_link_validation_aspect = aspect(
    implementation = _rust_link_validation_aspect_impl,
    attr_aspects = _NATIVE_DEP_ATTRS,
    doc = (
        "Traverses native dependency edges, accumulates the static Rust library identity " +
        "closures exposed by Rust targets, and enforces that each logical identity appears " +
        "with at most one configured crate instance within one native link unit (cc_binary, " +
        "cc_test, cc_shared_library)."
    ),
)

def _rust_link_checker_impl(ctx):
    """Validates the Rust identity closure of the forwarded native deps."""
    crates = []
    for dep in ctx.attr.deps:
        if RustLinkAggregationInfo in dep:
            crates.append(dep[RustLinkAggregationInfo].crates)

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
