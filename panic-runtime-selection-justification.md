# Panic runtime selection with `cc_common.link`

## Purpose

This note records the correctness justification for making rules_rust honor Rust's effective panic strategy when `experimental_use_cc_common_link` delegates the final link to Bazel's `cc_common.link`.

It is intended to support a future PR description and review. It distinguishes behavior demonstrated in Cargo/rustc from behavior inferred or reconstructed in rules_rust.

## Intended contract

Cargo owns profile and compilation-unit orchestration. rustc owns panic-strategy interpretation, panic-runtime selection, and final crate-graph compatibility checks.

Cargo translates the profile panic strategy into rustc's `-C panic=<strategy>` option:

- Cargo profile documentation: <https://github.com/rust-lang/cargo/blob/514c56dd7321eecbfdcf9b6479519cf4edfab906/doc/book/src/reference/profiles.md#L192-L211>
- Cargo compiler argument construction: <https://github.com/rust-lang/cargo/blob/514c56dd7321eecbfdcf9b6479519cf4edfab906/src/compiler/mod.rs#L1357-L1370>
- Cargo regression checking `-C panic=abort` on the relevant compilation units: <https://github.com/rust-lang/cargo/blob/514c56dd7321eecbfdcf9b6479519cf4edfab906/tests/testsuite/test.rs#L5017-L5065>

rustc then performs the final-link responsibilities:

1. It resolves the effective strategy from the last explicit `-C panic` option, or from the target default when no option is present: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/compiler/rustc_session/src/session.rs#L917-L921>.
2. `std` declares that a panic runtime is required: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/library/std/src/lib.rs#L236-L239>.
3. For final artifacts, rustc selects `panic_unwind`, `panic_abort`, or no runtime for `immediate-abort`. It deliberately skips this selection for rlib-only output: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/compiler/rustc_metadata/src/creader.rs#L942-L1010>.
4. It activates the selected runtime and validates the linked crate graph, including duplicate runtimes, incompatible required strategies, and `immediate-abort` constraints: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/compiler/rustc_metadata/src/dependency_format.rs#L410-L488>.

The resulting invariant is: the final artifact's panic runtime and linked crate graph must be compatible with the effective panic strategy. `panic_abort` and `panic_unwind` are alternatives, not an interchangeable or cumulative pair.

## Upstream test evidence

The Rust repository directly tests these behaviors:

- `-C panic=abort` links successfully with the abort runtime: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/tests/ui/panic-runtime/link-to-abort.rs>.
- An unwind final artifact rejects an abort-required dependency: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/tests/ui/panic-runtime/need-abort-got-unwind.rs>.
- An abort final artifact may link ordinary crates capable of unwinding, because abort at the final boundary is compatible with those crates: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/tests/ui/panic-runtime/abort-link-to-unwinding-crates.rs>.
- Two panic runtimes are prohibited: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/tests/ui/panic-runtime/two-panic-runtimes.rs>.
- `immediate-abort` rejects the normally precompiled sysroot instead of failing later with unresolved panic entry points: <https://github.com/rust-lang/rust/blob/f7d782a3be46d6bb4b9792fe69a61db389ba1769/tests/ui/panic-runtime/immediate-abort-default-sysroot.rs>.

## Existing rules_rust violation

With `experimental_use_cc_common_link`, rules_rust asks rustc to emit an object and lets Bazel own the final link. That removes rustc from the point where the final runtime is activated and the complete linked graph is checked.

The baseline rules_rust implementation reconstructed the standard-library closure independently. When the sysroot contained `panic_unwind`, it unconditionally removed `panic_abort` and retained the unwind closure. Panic strategy was not an input to this selection.

The resulting mismatch was:

```text
Rust compilation: -C panic=abort
Bazel CppLink:    libpanic_unwind
```

Thus the requested panic strategy affected code generation but was not respected by the replacement final-link orchestrator.

## Failing-first proof

The link-action regression was applied to unmodified production code at rules_rust revision `a6963b5cef5ceeca0a80d75602026eaabb50fd6d`.

Command:

```text
bazel test //unit:panic_abort_runtime_is_abort
```

Baseline result:

```text
did not expect panic_unwind in linker invocation
//unit:panic_abort_runtime_is_abort FAILED
```

This inspects the generated `CppLink` action rather than relying only on successful process exit. The baseline action demonstrably received the wrong runtime.

After the implementation, the concrete `CppLink` command contains `libpanic_abort` and does not contain `libpanic_unwind`.

## Differential rustc proof

A direct rustc probe used this graph:

```text
abort dependency rlib -> default-unwind intermediate rlib -> final binary
```

Observed results:

```text
compile abort dependency rlib                         exit 0
compile default-unwind intermediate rlib              exit 0
compile unwind binary with --emit=obj                 exit 0
perform normal rustc unwind final link                exit 1
perform rustc -Cpanic=abort final link                exit 0
```

The normal final link reports:

```text
the crate `dep` requires panic strategy `abort` which is incompatible
with this crate's strategy of `unwind`
```

This demonstrates that successful object emission is not proof of a valid final panic graph. The operation used before `cc_common.link` does not perform the same final-artifact check as a normal rustc link.

## Why rules_rust owns the fix

Forwarding `-C panic=abort` is necessary but insufficient: rules_rust already forwards the option to rustc compilation.

Once rules_rust replaces rustc as the final-link orchestrator, rules_rust also assumes responsibility for reconstructing the final linker's panic-runtime inputs. Cargo cannot repair the independently constructed Bazel link action, and rustc cannot amend that action after emitting the object.

The appropriate implementation layer is therefore the rules_rust code that:

- resolves the effective Rust codegen options;
- constructs the standard-library and allocator `CcInfo` closure;
- propagates Rust linkage through dependencies; and
- invokes `cc_common.link`.

## Implemented approach

The implementation uses a narrower, explicit contract:

- `cc_common_link_panic_strategy` declares `target-default`, `unwind`, `abort`,
  or `immediate-abort` for configurations using `experimental_use_cc_common_link`;
- generated toolchains query the selected rustc's `panic="..."` target cfg rather
  than maintaining a target list;
- when repository evaluation cannot execute a compiler selected for a remote
  platform, the toolchain records `unknown`: `target-default` then fails closed
  for cc-common linking and asks for an explicit strategy;
- the selected strategy is appended to rustc as a final canonical
  `-Cpanic=<strategy>` argument, after authored and opaque argument sources;
- the same value selects the standard-library/allocator `CcInfo` closure for the
  final `cc_common.link` action and every target-configuration Rust library;
- normal rustc-owned final links are unchanged when cc-common linking is disabled;
- explicit strategy selection requires configuration-wide cc-common linking so
  dependencies cannot silently use another intent;
- `immediate-abort` fails during analysis unless the sysroot has the matching
  default strategy; and
- non-unwind `rust_test` fails during analysis because stable rustc requires the
  unsupported `-Zpanic_abort_tests` option for such test harnesses.

The implementation intentionally does not parse arbitrary rustc flags or emulate
metadata-only per-crate compatibility requirements.

## Focused test results

The following focused tests pass after the change:

```text
//unit:default_panic_runtime_is_unwind                           PASSED
//unit:canonical_abort_setting_controls_codegen_and_link         PASSED
//unit:canonical_abort_setting_controls_rust_dependency_codegen  PASSED
//unit:canonical_unwind_setting_controls_codegen_and_link        PASSED
//unit:panic_setting_does_not_change_rustc_owned_link            PASSED
//unit:panic_immediate_abort_rejects_unwind_std                  PASSED
//unit:panic_abort_rust_test_is_rejected                         PASSED
//unit:panic_abort_std_dylib_is_rejected                         PASSED
//unit:explicit_panic_strategy_requires_global_cc_common         PASSED
//unit:explicit_panic_strategy_rejects_rule_opt_out              PASSED
```

A Linux hermetic-LLVM analysis regression passes as
`//unit:panic_abort_runtime_is_abort_linux_llvm`. A Linux-only runtime target,
`//unit:panic_abort_runtime_linux`, launches a child that panics and requires the
child to terminate with `SIGABRT`.

On a macOS host, the runtime binary cross-builds successfully as an x86-64 Linux
ELF. Its Rust action ends in `-Cpanic=abort`; its `CppLink` action contains
`libpanic_abort` and excludes `libpanic_unwind`.

The Linux runtime test also passes under remote execution with the hermetic LLVM
toolchain. The test launches itself as a child, panics in the child, and observes
Linux signal 6 (`SIGABRT`) in the parent. BuildBuddy's default worker image was
too old for the hermetic process wrapper; the passing invocation therefore used
`--remote_default_exec_properties=container-image=docker://ubuntu:22.04`.

```text
bazel test --config=remote \
  --remote_executor=grpcs://remote.buildbuddy.io \
  --remote_default_exec_properties=container-image=docker://ubuntu:22.04 \
  --extra_execution_platforms=@llvm//platforms:linux_x86_64 \
  --extra_toolchains=@llvm//toolchain:all \
  --platforms=@llvm//platforms:linux_x86_64 \
  --@rules_rust//rust/settings:experimental_use_cc_common_link \
  --@rules_rust//rust/settings:cc_common_link_panic_strategy=abort \
  //unit:panic_abort_runtime_linux
```

Result: one test executed and passed. The downloaded output is an x86-64 Linux
ELF, and `llvm readelf -h` reports `ELF64` / `Advanced Micro Devices X86-64`.

For the same remote Linux platform, omitting an explicit strategy while retaining
`target-default` fails during analysis with:

```text
cc_common_link_panic_strategy=target-default cannot be resolved because the
selected rustc cannot run on the Bazel client; set the strategy explicitly
```

This negative result is intentional: repository rules execute on the macOS Bazel
client, where the selected Linux rustc cannot run. Guessing a target default
would violate the exact-toolchain contract.

## Remaining architectural limitations

This change does not establish complete equivalence between arbitrary external linking of rlibs and a rustc-owned final link.

rustc can derive `required_panic_strategy` from compiled metadata and source-level properties, including FFI-unwind requirements. Bazel analysis cannot inspect a generated rmeta artifact before constructing the `cc_common.link` action. The propagated Starlark information therefore covers strategies known from rule configuration and flags, not every metadata-only requirement rustc may discover.

Similarly, a C++ target can independently merge multiple public Rust `CcInfo` providers without a single Rust final-link rule that validates their combined strategy requirements.

These are existing architectural gaps. Fixing them would require a broader design, such as preserving more Rust linkage metadata until an execution-time link orchestrator or introducing a single aggregation point for Rust rlibs consumed by C++.

The current justification is consequently narrower and precise: rules_rust must not unconditionally select `panic_unwind` when it owns the final link for a crate whose effective configured strategy is abort, and it must reproduce the final-link checks that are representable in Bazel analysis.

## Implemented simplification: a cc-common-link-owned panic intent

### Correctness boundary

Define a narrower supported contract instead of attempting to reconstruct every
per-crate rustc decision from arbitrary command-line flags:

- Normal rustc-owned final links remain unchanged; rustc remains authoritative.
- Whenever rules_rust replaces rustc's final link with `cc_common.link`, a typed
  Bazel setting declares the intended panic strategy for that Bazel-owned link.
- The declared strategy is configuration-wide for the target Rust linkage graph,
  not a best-effort inference from individual crates.
- rules_rust passes the matching `-Cpanic=<strategy>` to affected Rust compile
  actions and selects the matching std/allocator closure for every Rust `CcInfo`
  that can reach the Bazel-owned final link.
- The rules-generated panic flag is ordered after user/toolchain Rust flags, so
  the declared setting is canonical even when earlier flags use another spelling
  or arrive through an opaque `Args` value.
- Unsupported cases fail closed rather than claiming rustc equivalence.

Candidate setting:

```text
--@rules_rust//rust/settings:cc_common_link_panic_strategy=
    target-default | unwind | abort | immediate-abort
```

The setting has no effect on a normal rustc-owned final link. `target-default`
must resolve from the exact selected Rust toolchain/target, not a hand-maintained
target list. If the selected compiler cannot run during repository evaluation,
`target-default` fails closed for cc-common linking. Explicit strategies express
user intent directly and remain usable for that remote-platform case.

### Why this can remove current machinery

If the setting is canonical and applies uniformly to all target-configuration
Rust crates contributing to the Bazel-owned link, rules_rust no longer needs to:

- parse every rustc spelling and reproduce last-option-wins at analysis time;
- add an escape hatch describing the contents of opaque `Args` values;
- propagate every crate's effective strategy through `RustCcInfo`;
- thread that provider through crate groups, Prost aspects, and dependency
  transformation helpers; or
- partially reproduce rustc's per-crate compatibility algorithm from strategy
  labels that do not contain rustc's metadata-only requirements anyway.

The implementation still must:

- construct/select distinct unwind, abort, and immediate-abort std/allocator
  `CcInfo` closures;
- apply the setting to Rust libraries whose public `CcInfo` reaches the final
  C++ link, not only to the final binary's object compilation;
- append the canonical rustc flag after every other Rust flag source;
- resolve `target-default` accurately;
- reject non-unwind std dylibs unless the toolchain supplies a matching dylib;
- reject `immediate-abort` unless the sysroot was built for it; and
- test the generated Rust actions and final C++ link artifact/action.

Applying the setting only to the final Rust crate would be incorrect. An rlib's
public `CcInfo` can already contain its std panic closure; leaving dependencies
on the unwind closure while selecting abort for the final binary can reintroduce
both runtimes. The setting is scoped to cc-common-link behavior, but must be
visible throughout the target linkage graph.

### Deliberate boundaries

This simplified contract does not support independently selected panic strategies
inside one Bazel-owned Rust link graph. In particular:

- per-rule panic overrides are not supported under `cc_common.link`;
- configuration transitions that combine Rust libraries built under different
  panic settings must be rejected or documented unsupported;
- arbitrary prebuilt rlibs with metadata-only panic requirements remain outside
  the analysis-time guarantee;
- a `cc_binary` directly aggregating Rust libraries from different configurations
  remains outside the guarantee unless a single validating aggregation rule is
  introduced; and
- `no_std`, proc-macro/exec-configuration behavior, and std dylib support need
  explicit decisions rather than accidental inheritance.

These boundaries are stricter than rustc, but they are internally complete: for
the supported intent, one declared strategy controls both code generation and the
runtime closure. Broader mixed-strategy compatibility can be added later only if
a concrete use case justifies the provider and validation machinery.

### Acceptance criteria

1. With ordinary rustc final linking, the setting does not change compile or link
   actions.
2. With `cc_common.link` and explicit `abort`, every relevant target Rust compile
   action receives a final `-Cpanic=abort`; the C++ link contains `panic_abort`
   and excludes `panic_unwind`.
3. With explicit `unwind`, compile actions receive unwind; the C++ link contains
   `panic_unwind` and excludes `panic_abort`.
4. An earlier conflicting panic flag, including one in opaque `Args`, cannot
   override the canonical setting; action inspection proves final argument order.
5. A transitive Rust-library chain cannot reintroduce the other runtime through
   public `CcInfo`; final action/artifact inspection proves the closure.
6. `target-default` matches the exact selected rustc target configuration,
   including an abort-default target and a custom target JSON.
7. Unsupported std-dylib, `immediate-abort` sysroot, mixed-transition, and chosen
   `no_std` boundaries produce explicit analysis errors.
8. A hermetic-LLVM Linux test inspects the final ELF/link action and runs a small
   binary as supplementary behavioral evidence.

### Implementation plan used

1. Add the typed setting and document its supported scope in the setting's own
   help text.
2. Resolve `target-default` from the selected Rust toolchain and expose the value
   in toolchain data used by analysis.
3. Append the canonical rustc panic option last for target Rust crates belonging
   to a configuration using Bazel-owned final linking.
4. Keep the strategy-indexed std/allocator closure construction and select the
   declared closure for final links and Rust-library public `CcInfo`.
5. Remove the flag parser, opaque-Args strategy parameter, transitive
   `RustCcInfo.panic_strategies`, crate-group/Prost plumbing, and representable
   per-crate compatibility checks.
6. Add failing-first action tests for abort selection, argument precedence, and a
   transitive rlib chain; add negative tests for every declared unsupported case.
7. Add the Linux hermetic-LLVM action/artifact/runtime coverage and compare the
   observable result with an equivalent rustc-owned link.

The implementation requires explicit strategies to be paired with the
configuration-wide `experimental_use_cc_common_link` setting. A parent-only
rule override is rejected because its dependencies cannot observe that choice.
