"""Build the normalizer without recursively normalizing its own dependencies."""

load("@with_cfg.bzl", "with_cfg")

rust_source_normalizer, _rust_source_normalizer = with_cfg(native.alias, executable = True).set(
    Label("//rust/private:source_normalizer"),
    Label("//rust/private:no_source_normalizer"),
).build()
