# Panic runtime selection simplification plan

## Status

Implemented on `cerisier/rust-panic-runtime-selection`; verification recorded
below. Not yet proposed as a PR.

Reviewed by a fresh-context agent. Verdict: accept the singular-`CcInfo`
architecture with the scope corrections recorded below.

## Goal

When rules_rust uses `cc_common.link`, one explicit Bazel configuration value
must control both:

- Rust panic code generation; and
- the panic-runtime closure supplied to the final C++ link.

Do this without parsing arbitrary rustc flags, propagating per-crate strategy
providers, querying rustc during repository evaluation, or storing every possible
standard-library closure in plural `CcInfo` maps.

## Supported contract

Add or reshape the build setting as:

```text
cc_common_link_panic_strategy = unset | unwind | abort
```

- `unset` is the default.
- With global cc-common linking disabled, preserve existing behavior.
- Every effective cc-common final link requires both:
  - global `experimental_use_cc_common_link = true`; and
  - an explicit `unwind` or `abort` strategy.
- Reject rule-local cc-common opt-in when the global setting/strategy pair is
  absent. Dependencies cannot observe a parent rule's local intent.
- Reject a rule-local opt-out while global explicit mode is active.
- Reject distributed ThinLTO when it would activate `cc_common.link` without the
  same global explicit contract.
- Under global explicit mode, append the canonical panic flag to every non-exec
  target-configuration Rust compilation, including artifacts whose final link is
  still owned by rustc. This keeps shared rlib graphs internally consistent.
- Rustc-owned target links remain unchanged only when global explicit mode is
  disabled. Under global mode, rustc still owns their runtime selection, but it
  receives the configured panic strategy.
- Exec-configured crates and proc macros retain existing behavior.

Initially supported strategies are only `unwind` and `abort`. Stable rustc and
Cargo profiles support these values. Defer `immediate-abort` until rules_rust has
a concrete supported sysroot contract for it.

## Singular provider architecture

Each configured Bazel target/toolchain instance needs one runtime closure, not a
map of alternatives.

Keep and populate the existing singular fields:

- `libstd_and_allocator_ccinfo`
- `libstd_and_global_allocator_ccinfo`
- `nostd_and_global_allocator_ccinfo`

The first two use the one selected target-configuration strategy when global
explicit mode is active. Otherwise they retain the original default behavior.
The custom allocator rule derives the same scalar from its configured Rust
toolchain and populates the same singular fields.

Remove:

- `libstd_and_allocator_ccinfos`
- `libstd_and_global_allocator_ccinfos`
- strategy-to-`CcInfo` maps and their selector helper
- repository-time `rustc --print cfg` execution
- `default_panic_strategy` repository/toolchain plumbing
- `unknown` remote-platform fallback handling
- `target-default` and initial `immediate-abort` support

## Boundaries

- Preserve `nostd_and_global_allocator_ccinfo`; do not regress existing no-std
  users in global-off legacy mode.
- For the first implementation, reject no-std targets under global explicit
  panic mode unless focused investigation proves and documents a sound contract.
- Continue rejecting abort `rust_test` while stable rustc requires the unsupported
  `-Zpanic_abort_tests` behavior.
- Continue rejecting abort with `experimental_link_std_dylib`; the distributed
  std dylib is built for unwind.
- Configuration transitions can still produce unwind and abort `CcInfo` values
  that a `cc_binary` merges directly. A plural map does not solve this. Document
  mixed-transition/direct-C++ aggregation as outside the guarantee until a
  scalar strategy marker and validating Rust aggregation point are designed.

## Implementation sequence

1. Preserve the existing failing-first baseline regression.
2. Add the missing boundary tests before changing production code.
3. Reduce the setting to `unset | unwind | abort` and remove target-default
   discovery/plumbing.
4. Resolve one effective scalar per configured target/toolchain instance.
5. Build only the existing singular std/default-allocator and
   std/global-allocator closures with that scalar.
6. Make `rust_allocator_libraries` use the same scalar and singular provider
   fields.
7. Append the canonical `-Cpanic=<strategy>` argument last for every non-exec
   target Rust compilation under global explicit mode.
8. Add explicit diagnostics for missing global mode/strategy, local opt-in,
   local opt-out, distributed ThinLTO, rust tests, std dylibs, and the chosen
   no-std boundary.
9. Remove plural/provider/default-resolution machinery only after focused tests
   pass with singular selection.
10. Inspect the final diff for obsolete compatibility plumbing and documentation
    that still describes target-default or plural closures.

## Required tests

- Baseline regression fails before the fix and passes after it.
- Explicit abort:
  - final Rust action ends with `-Cpanic=abort` despite an earlier conflicting
    user flag;
  - transitive target rlibs receive the same final flag;
  - final `CppLink` contains exactly one `panic_abort` and no `panic_unwind`.
- Explicit unwind proves the inverse runtime closure.
- A rustc-owned staticlib sharing target rlibs receives the configured strategy
  under global mode and links successfully.
- With global mode off, ordinary rustc-owned actions remain byte-for-byte
  unaffected by the panic setting.
- Default and global custom allocator paths select the same singular closure.
- Proc macro plus transitive exec rlibs remain on exec/default behavior when the
  target graph uses abort.
- Rule-local opt-in, global opt-out, and distributed-ThinLTO-without-contract
  configurations fail with actionable diagnostics.
- Abort rust test, abort std dylib, and the selected no-std boundary fail during
  analysis.
- A split-transition test records that direct C++ aggregation of differently
  configured Rust providers is unsupported and not falsely validated.
- Hermetic LLVM Linux action inspection proves abort-only runtime inputs.
- Downloaded output is a Linux ELF.
- Linux runtime test observes child termination by `SIGABRT`.

## Completion criteria

- No plural panic-runtime `CcInfo` fields or maps remain.
- No repository-time compiler execution remains for panic selection.
- One configuration scalar controls code generation and singular runtime
  closure selection.
- Every path that activates `cc_common.link` either satisfies the explicit
  global contract or fails during analysis.
- Exec/proc-macro and global-off behavior remain unchanged.
- Demonstrated facts, unsupported boundaries, exact commands, and observed
  action/artifact/runtime results are incorporated into the future PR
  justification.

## Implementation result

- Setting reduced to `unset | unwind | abort`.
- Repository-time rustc query and target-default toolchain plumbing removed.
- Existing singular std/allocator `CcInfo` fields retained; plural maps removed.
- One scalar controls target Rust code generation and the constructed runtime
  closure; exec configurations keep legacy behavior.
- Missing global intent, local opt-in/opt-out, distributed ThinLTO, no-std,
  aborting test harnesses, and abort with std dylib have focused diagnostics.
- Previously failing missing-intent and no-std regressions now pass.
- Focused cc-common-link, stdlib, toolchain, and complete LTO suites pass.
- Linux hermetic-LLVM action contains `panic_abort` only; downloaded output is
  x86-64 ELF; uncached remote runtime test observes `SIGABRT` and passes.
