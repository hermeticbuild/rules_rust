"""C++ toolchain for analyzing shared ThinLTO backends."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "action_config", "feature", "flag_group", "flag_set", "tool")
load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

def _config_impl(ctx):
    return [cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "shared-backends-test",
        host_system_name = "unknown",
        target_system_name = "unknown",
        target_cpu = "x86_64",
        target_libc = "unknown",
        compiler = "clang",
        abi_version = "unknown",
        abi_libc_version = "unknown",
        features = [
            feature(name = "supports_pic", enabled = True),
            feature(name = "supports_start_end_lib", enabled = True),
            feature(name = "thin_lto"),
            feature(name = "thin_lto_linkstatic_tests_use_shared_nonlto_backends"),
            feature(name = "thin_lto_all_linkstatic_use_shared_nonlto_backends"),
            feature(
                name = "backend_pic",
                enabled = True,
                flag_sets = [flag_set(
                    actions = [ACTION_NAMES.lto_backend],
                    flag_groups = [flag_group(flags = ["-fPIC"], expand_if_available = "pic")],
                )],
            ),
        ],
        action_configs = [action_config(
            action_name = action,
            enabled = True,
            tools = [tool(path = "/bin/false")],
        ) for action in [
            ACTION_NAMES.lto_backend,
            ACTION_NAMES.lto_index_for_executable,
            ACTION_NAMES.lto_index_for_dynamic_library,
            ACTION_NAMES.lto_index_for_nodeps_dynamic_library,
        ]],
    )]

_config = rule(
    implementation = _config_impl,
    provides = [CcToolchainConfigInfo],
)

def shared_backends_toolchain(name):
    """Declare a toolchain that supports the shared-backend features."""
    _config(name = name + "_config")
    native.filegroup(name = name + "_files")
    cc_toolchain(
        name = name + "_impl",
        toolchain_config = ":" + name + "_config",
        all_files = ":" + name + "_files",
        compiler_files = ":" + name + "_files",
        linker_files = ":" + name + "_files",
        ar_files = ":" + name + "_files",
        dwp_files = ":" + name + "_files",
        objcopy_files = ":" + name + "_files",
        strip_files = ":" + name + "_files",
    )
    native.toolchain(
        name = name,
        toolchain = ":" + name + "_impl",
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    )
