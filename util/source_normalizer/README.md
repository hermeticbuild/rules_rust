# Rust production source normalization

This Bazel action uses `syn` and `quote` to give `rustc` stable
source inputs when ordinary comments, formatting or test-only items change.

The tool treats `test` as false and evaluates `all`, `any`, `not`, and
`cfg_attr` conservatively. Unknown features and target predicates stay in the
output for `rustc` to evaluate. It removes disabled items at file, module,
block, impl, trait and foreign-item scope, as well as plain `#[test]` functions.
Other conditional syntax, including fields and expression attributes, remains
for `rustc`; edits there can still invalidate the cache.

## Bazel use

```starlark
load("@rules_rust//rust:defs.bzl", "rust_library")

rust_library(
    name = "library",
    srcs = glob(["src/**/*.rs"]),
    crate_root = "src/lib.rs",
    edition = "2024",
)
```

The action runs automatically inside every `rust_library`, before both full and
metadata compilation. `rust_test(crate = ":library")`, Clippy, rustfmt and rustdoc retain
the original sources through the existing crate provider.

The normalizer is supplied by the Rust toolchain, with no per-library setting.
Its private `with_cfg` bootstrap transition builds itself and its dependencies without
normalization while retaining Cargo build-script support.

The action accepts source and asset depsets and produces one directory tree.
It preserves repository-relative paths for checked-in files, generated files,
cross-package sources and directory inputs. Rustc uses its existing `root_path`
support to compile from that tree.

Explicit `compile_data` also remains available at its original paths for location
expansions. A source declared in `compile_data` or `data` therefore remains a raw
compiler input and can still invalidate compilation when its comments change.

Module resolution stays with rustc. An out-of-line test module is normalized
independently: plain `#[test]` functions disappear, but unguarded helpers remain.
Use a file-level `#![cfg(test)]` guard to make all test-only edits in such a file
irrelevant to production compilation.

## Semantic boundary

The compiler remaps staged filenames to their logical source paths. Regeneration
changes line and column locations, diagnostics, debug information, `line!`,
`column!`, panic and `#[track_caller]` locations. Procedural macros that inspect
spans or source text can observe these changes.

Doc comments are retained as doc attributes: derives such as command-line and
schema generators can consume them. Opaque macro bodies are preserved verbatim,
including doc-comment syntax and template placeholders. Comments, formatting
and test syntax inside them remain, so edits there still invalidate compilation.
A procedural attribute macro can observe the rewritten AST of its annotated item,
including removed nested test items.

Complete `.rs` files declared in `srcs`, including files inside source
directories, are transformed. Files that `syn` cannot parse, such as `.rs`
templates and include fragments caught by source globs, pass through unchanged;
rustc still diagnoses invalid files it actually compiles. Other files are copied.
Assets or Rust fragments loaded with `include!`, `include_str!`, or
`include_bytes!` must be declared in `compile_data`; they are staged without
parsing. Source-text introspection, including reading an
`.rs` file with a relative `include_str!`, observes the normalized text. An explicit
location expansion pointing to original `compile_data` observes the original bytes.
