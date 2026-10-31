"""Run a real cfg query using a selected target toolchain and native build.rs."""

load("//rust/platform:triple.bzl", "triple")

def _query_toolchain_impl(ctx):
    # Reuse native compiler binaries and their declared input closure. This
    # toolchain only queries Windows cfg; it never compiles Windows code.
    base = ctx.attr.base[platform_common.ToolchainInfo]
    fields = {name: getattr(base, name) for name in dir(base)}
    fields.update(
        target_triple = triple("x86_64-pc-windows-msvc"),
        target_flag_value = "x86_64-pc-windows-msvc",
        target_json = None,
        target_arch = "x86_64",
        target_os = "windows",
        target_abi = "msvc",
        extra_rustc_flags = [
            "-C",
            "target-cpu=x86-64",
            "-Ctarget-cpu=x86-64-v3",
            "-Ctarget-feature=+crt-static",
        ],
        extra_exec_rustc_flags = ["-Ctarget-cpu=x86-64-v4"],
        extra_rustc_flags_for_crate_types = {"rlib": ["-Ctarget-feature=+avx512f"]},
    )
    return [platform_common.ToolchainInfo(**fields)]

query_toolchain = rule(
    implementation = _query_toolchain_impl,
    attrs = {
        "base": attr.label(
            default = "//rust/toolchain:current_rust_toolchain",
            cfg = "exec",
        ),
    },
)

def _query_configuration_impl(settings, _attr):
    return {
        "//command_line_option:platforms": str(Label(":windows_query")),
        "//command_line_option:extra_toolchains": [str(Label(":query_toolchain"))] + settings["//command_line_option:extra_toolchains"],
    }

_query_configuration = transition(
    implementation = _query_configuration_impl,
    inputs = ["//command_line_option:extra_toolchains"],
    outputs = ["//command_line_option:platforms", "//command_line_option:extra_toolchains"],
)

def _configured_build_script_impl(ctx):
    return [DefaultInfo(files = ctx.attr.script[0][DefaultInfo].files)]

configured_build_script = rule(
    implementation = _configured_build_script_impl,
    attrs = {
        "script": attr.label(cfg = _query_configuration),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
