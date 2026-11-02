"""Run a real cfg query using a selected target toolchain and native build.rs."""

load("//rust/platform:triple.bzl", "triple")

def _query_toolchain_impl(ctx):
    # Reuse native compiler binaries and their declared input closure. Windows
    # targets only query cfg; the other cases also compile a native library.
    base = ctx.attr.base[platform_common.ToolchainInfo]
    fields = {name: getattr(base, name) for name in dir(base)}
    if not ctx.attr.windows:
        flags = list(ctx.attr.extra_rustc_flags)
        if ctx.attr.explicit_sysroot:
            # The expanded value of --sysroot=$(RUST_SYSROOT).
            flags.append("--sysroot=" + base.sysroot)
        fields.update(extra_rustc_flags = flags)
        return [platform_common.ToolchainInfo(**fields)]

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
        "windows": attr.bool(default = True),
        "extra_rustc_flags": attr.string_list(),
        "explicit_sysroot": attr.bool(),
        "base": attr.label(
            default = "//rust/toolchain:current_rust_toolchain",
            cfg = "exec",
        ),
    },
)

def _query_configuration_impl(settings, attr):
    return {
        "//command_line_option:platforms": str(Label(":windows_query" if attr.windows else ":native_query")),
        "//command_line_option:extra_toolchains": [str(attr.toolchain)] + settings["//command_line_option:extra_toolchains"],
        "//rust/settings:toolchain_generated_sysroot": attr.generated_sysroot,
        "//rust/settings:error_format": attr.error_format,
        "//rust/settings:rustc_output_diagnostics": attr.capture_diagnostics,
    }

_query_configuration = transition(
    implementation = _query_configuration_impl,
    inputs = ["//command_line_option:extra_toolchains"],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:extra_toolchains",
        "//rust/settings:toolchain_generated_sysroot",
        "//rust/settings:error_format",
        "//rust/settings:rustc_output_diagnostics",
    ],
)

def _configured_build_script_impl(ctx):
    return [DefaultInfo(files = ctx.attr.script[0][DefaultInfo].files)]

configured_build_script = rule(
    implementation = _configured_build_script_impl,
    attrs = {
        "script": attr.label(cfg = _query_configuration),
        "windows": attr.bool(default = True),
        "toolchain": attr.label(default = ":query_toolchain"),
        "generated_sysroot": attr.bool(default = True),
        "error_format": attr.string(default = "human"),
        "capture_diagnostics": attr.bool(),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
