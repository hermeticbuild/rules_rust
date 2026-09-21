# Copyright 2026 The Bazel Authors. All rights reserved.
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

"""Rust identity-closure aggregation across native dependency edges."""

load(":providers.bzl", "BuildInfo", "CrateInfo", "RustLinkClosureInfo", "TestCrateInfo")
load(":rust_crate_identity.bzl", "validate_crate_identity_closure")

RustLinkAggregationInfo = provider(
    doc = "Aggregates static Rust identity closures along native dependency edges.",
    fields = {
        "crates": "depset[RustCrateIdentityInfo]: Static Rust identity closure reached so far.",
    },
)

_NATIVE_DEP_ATTRS = ["deps", "implementation_deps"]
_NATIVE_LINK_UNIT_KINDS = ("cc_binary", "cc_test", "cc_shared_library")

def _rust_link_validation_aspect_impl(target, ctx):
    """Propagates static Rust identity closures across native dependency edges."""
    if RustLinkClosureInfo in target:
        closure = target[RustLinkClosureInfo]
        if closure.linkage != "static":
            return []
        return [RustLinkAggregationInfo(crates = closure.crates)]

    # Rust executables, tests, proc macros, and build scripts are independent
    # link/host units.
    # Library-producing rules are handled above through RustLinkClosureInfo.
    # Do not look through a legacy/custom Rust boundary that lacks that provider.
    if BuildInfo in target or CrateInfo in target or TestCrateInfo in target:
        return []

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
        if ctx.rule.kind == "cc_shared_library":
            # The shared library is independently linked. Its internal static
            # Rust crates do not belong to a consuming link unit.
            return []

    return [aggregation]

native_rust_link_validation_aspect = aspect(
    implementation = _rust_link_validation_aspect_impl,
    attr_aspects = _NATIVE_DEP_ATTRS,
    doc = (
        "Traverses native dependency edges, accumulates static Rust library identity " +
        "closures, validates native terminal link units, and treats shared libraries " +
        "as opaque dynamic boundaries."
    ),
)
