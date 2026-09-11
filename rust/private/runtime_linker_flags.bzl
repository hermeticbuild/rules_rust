"""Compiler-driver runtime options that are redundant for rustc-owned linking."""

def can_omit_runtime_selection(flags):
    """Whether known, ordered rustc flags leave default linker libraries disabled.

    Opaque Args, response files and malformed options are conservative: preserve
    the C toolchain's flags rather than changing an unknown link configuration.

    Args:
        flags: Effective rustc options in precedence order, or an opaque Args.

    Returns:
        True only when automatic default linker libraries are disabled.
    """
    if type(flags) != "list":
        return False
    enabled = False  # rustc's default for -C default-linker-libraries
    codegen_next = False
    for flag in flags:
        if type(flag) != "string" or flag.startswith("@"):
            return False
        if flag == "--target" or flag.startswith("--target="):
            return False
        option = None
        if codegen_next:
            option = flag
            codegen_next = False
        elif flag in ("-C", "--codegen"):
            codegen_next = True
        elif flag.startswith("-C"):
            option = flag[2:].removeprefix("=")
        elif flag.startswith("--codegen="):
            option = flag[len("--codegen="):]
        if option == None:
            continue
        if option.startswith("linker="):
            return False  # The final compiler driver is no longer known.
        if option == "default-linker-libraries":
            enabled = True
        elif option.startswith("default-linker-libraries="):
            value = option.split("=", 1)[1]
            if value in ("yes", "true", "on", "y", "1"):
                enabled = True
            elif value in ("no", "false", "off", "n", "0"):
                enabled = False
            else:
                return False
    return not enabled and not codegen_next

def omit_unused_runtime_selection(link_args):
    """Remove only the two redundant automatic runtime choices, preserving order."""
    return [arg for arg in link_args if arg not in (
        "--unwindlib=none",
        "-unwindlib=none",
        "-rtlib=compiler-rt",
        "--rtlib=compiler-rt",
    )]
