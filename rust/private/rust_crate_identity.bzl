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

"""Shared Rust crate-instance link validation.

Used by both the intrinsic Rust link rules (`rustc.bzl`) and the native
(C/C++) link-validation aspect so there is a single, consistent definition of
the enforced invariant:

> Within one configured native link unit, each non-empty logical Rust library
> identity may correspond to at most one configured Rust crate instance.
"""

def validate_crate_identity_closure(owner, identities):
    """Fails when one link unit contains incompatible instances of one identity.

    Args:
        owner (Label): The link unit owner, used only in diagnostics.
        identities (list[RustCrateIdentityInfo]): The Rust identity records in
            the link unit's static closure.
    """
    instances_by_id = {}
    for identity in identities:
        logical_id = identity.logical_id
        if not logical_id:
            continue
        instances = instances_by_id.get(logical_id)
        if instances == None:
            instances = {}
            instances_by_id[logical_id] = instances
        instances[identity.crate_instance] = identity

    conflicting_ids = [
        logical_id
        for logical_id, instances in instances_by_id.items()
        if len(instances) > 1
    ]
    if not conflicting_ids:
        return

    lines = [
        "{} would link incompatible instances of the same Rust library:".format(owner),
    ]
    for logical_id in sorted(conflicting_ids):
        instances = instances_by_id[logical_id]
        lines.extend([
            "",
            "  logical identity: {}".format(logical_id),
        ])
        for identity in sorted(instances.values(), key = lambda i: str(i.owner)):
            lines.extend([
                "",
                "  {}".format(identity.owner),
                "    crate instance: {}".format(identity.crate_instance),
            ])

    lines.extend([
        "",
        "A native link unit may contain at most one configured Rust crate instance",
        "for each logical Rust library identity.",
    ])
    fail("\n".join(lines))
