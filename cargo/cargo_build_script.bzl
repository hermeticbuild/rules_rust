"""# cargo_build_script.bzl

For C/C++ toolchains using JSON version-0 VFS overlays, opt in with
`features = ["cargo-rebase-json-vfs-overlays"]` to preserve relative paths
when the build script changes working directory. The runner creates temporary
copies without modifying toolchain inputs; arbitrary YAML is not supported.
"""

load(
    "//cargo/private:cargo_build_script_wrapper.bzl",
    _cargo_build_script = "cargo_build_script",
)

cargo_build_script = _cargo_build_script
