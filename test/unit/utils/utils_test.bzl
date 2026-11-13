""" Unit tests for functions defined in utils.bzl. """

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//rust/private:utils.bzl", "decode_crate_name_as_label_for_testing", "determine_lib_name", "determine_output_hash", "encode_label_as_crate_name", "encode_raw_string_for_testing", "should_encode_label_in_crate_name", "substitutions_for_testing")

def _encode_label_as_crate_name_test_impl(ctx):
    env = unittest.begin(ctx)

    # Typical cases.
    asserts.equals(
        env,
        "x_y_y_x_z",
        encode_label_as_crate_name("x/y", "z"),
    )
    asserts.equals(
        env,
        "some_y_package_x_target",
        encode_label_as_crate_name("some/package", "target"),
    )

    # Target name includes a character illegal in crate names.
    asserts.equals(
        env,
        "some_y_package_x_foo_y_target",
        encode_label_as_crate_name("some/package", "foo/target"),
    )

    # Package/target includes some of the encodings.
    asserts.equals(
        env,
        "some_zy__y_package_x_target_zpd_foo",
        encode_label_as_crate_name("some_y_/package", "target_pd_foo"),
    )

    # Some pathological cases: test that round-tripping the encoding works as
    # expected.

    # Label includes a quoted encoding.
    package = "_zpd_"
    target = "target"
    asserts.equals(env, "_zz_pd__x_target", encode_label_as_crate_name(package, target))
    asserts.equals(env, package + ":" + target, decode_crate_name_as_label_for_testing(encode_label_as_crate_name(package, target)))

    package = "x_y_y"
    target = "z"
    asserts.equals(env, "x_zy_y_x_z", encode_label_as_crate_name(package, target))
    asserts.equals(env, package + ":" + target, decode_crate_name_as_label_for_testing(encode_label_as_crate_name(package, target)))

    # Package is identical to a valid encoding already.
    package = "_zz_pd__x_target"
    target = "target"
    asserts.equals(env, "_zz_z_zpd__zx_target_x_target", encode_label_as_crate_name(package, target))
    asserts.equals(env, package + ":" + target, decode_crate_name_as_label_for_testing(encode_label_as_crate_name(package, target)))
    return unittest.end(env)

def _substitutions_concatenate_test_impl(ctx):
    env = unittest.begin(ctx)

    # Every combination of orig + orig, orig + encoded, encoded + orig, and
    # encoded + encoded round trips the encoding successfully.
    all_symbols = [s for pair in substitutions_for_testing for s in pair]
    for s in all_symbols:
        for t in all_symbols:
            concatenated = s + t
            asserts.equals(env, decode_crate_name_as_label_for_testing(encode_raw_string_for_testing(concatenated)), concatenated)

    return unittest.end(env)

def _encode_raw_string_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, encode_raw_string_for_testing("some_project:utils"), "some_project_x_utils")
    asserts.equals(env, encode_raw_string_for_testing("_zpd_"), "_zz_pd_")

    # No surprises in the application of the substitutions, everything is
    # encoded as expected.
    for (orig, encoded) in substitutions_for_testing:
        asserts.equals(env, encode_raw_string_for_testing(orig), encoded)

    return unittest.end(env)

#
def _decode_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, decode_crate_name_as_label_for_testing("some_project_x_utils"), "some_project:utils")
    asserts.equals(env, decode_crate_name_as_label_for_testing("_zz_pd_"), "_zpd_")

    # No surprises in the application of the substitutions, everything is
    # decoded as expected.
    for (orig, encoded) in substitutions_for_testing:
        asserts.equals(env, decode_crate_name_as_label_for_testing(encoded), orig)

    return unittest.end(env)

def _is_third_party_crate_test_impl(ctx):
    env = unittest.begin(ctx)

    # A target at the root of the third-party dir is considered third-party:
    asserts.false(env, should_encode_label_in_crate_name("some_workspace", Label("//third_party:foo"), "//third_party"))

    # Targets in subpackages are detected properly:
    asserts.false(env, should_encode_label_in_crate_name("some_workspace", Label("//third_party/serde:serde"), "//third_party"))
    asserts.false(env, should_encode_label_in_crate_name("some_workspace", Label("//third_party/serde/v1:serde"), "//third_party"))

    # Ensure the directory name truly matches, and doesn't just include the
    # third-party dir as a substring (or vice versa).
    asserts.true(env, should_encode_label_in_crate_name("some_workspace", Label("//third_party_decoy:thing"), "//third_party"))
    asserts.true(env, should_encode_label_in_crate_name("some_workspace", Label("//decoy_third_party:thing"), "//third_party"))
    asserts.true(env, should_encode_label_in_crate_name("some_workspace", Label("//third_:thing"), "//third_party"))
    asserts.true(env, should_encode_label_in_crate_name("some_workspace", Label("//third_party_decoy/serde:serde"), "//third_party"))

    # Targets in rules_rust's repo should never be renamed.
    asserts.false(env, should_encode_label_in_crate_name("rules_rust", Label("//some_package:foo"), "//third_party"))

    return unittest.end(env)

encode_label_as_crate_name_test = unittest.make(_encode_label_as_crate_name_test_impl)
is_third_party_crate_test = unittest.make(_is_third_party_crate_test_impl)
substitutions_concatenate_test = unittest.make(_substitutions_concatenate_test_impl)
encode_raw_string_test = unittest.make(_encode_raw_string_test_impl)
decode_test = unittest.make(_decode_test_impl)

def _proc_macro_without_dylib_test_impl(ctx):
    env = unittest.begin(ctx)

    # UEFI does not support dynamic libraries, but proc macros may still be
    # analyzed in the target configuration before they are built for exec.
    toolchain = struct(dylib_ext = "", target_triple = "x86_64-unknown-uefi", target_os = "uefi", target_arch = "x86_64", target_abi = "")
    asserts.equals(env, "libderive-123.so", determine_lib_name("derive", "proc-macro", toolchain, "123"))

    # Platforms that support dynamic libraries retain their native extension.
    for extension in [".so", ".dylib", ".dll"]:
        toolchain = struct(dylib_ext = extension, target_triple = "", target_arch = "x86_64")
        asserts.equals(env, "libderive" + extension, determine_lib_name("derive", "proc-macro", toolchain))
        asserts.equals(env, "libdynamic" + extension, determine_lib_name("dynamic", "dylib", toolchain))
        asserts.equals(env, "libdynamic" + extension, determine_lib_name("dynamic", "cdylib", toolchain))
    return unittest.end(env)

_proc_macro_without_dylib_test = unittest.make(_proc_macro_without_dylib_test_impl)

def _configuration_independent_output_hash_test_impl(ctx):
    env = unittest.begin(ctx)
    label = Label("//test:crate")
    def_root = "bazel-out/k8-fastbuild-ST-first/bin"
    other_root = "bazel-out/k8-fastbuild-ST-second/bin"
    first = struct(path = def_root + "/pkg/lib.rs", root = struct(path = def_root))
    second = struct(path = other_root + "/pkg/lib.rs", root = struct(path = other_root))
    asserts.equals(env, determine_output_hash(first, label), determine_output_hash(second, label))

    # Keep distinct labels and relative paths distinct after normalization.
    different = struct(path = other_root + "/other/lib.rs", root = struct(path = other_root))
    asserts.true(env, determine_output_hash(first, label) != determine_output_hash(different, label))
    asserts.true(env, determine_output_hash(first, label) != determine_output_hash(first, Label("//test:other")))
    source = struct(path = "pkg/lib.rs", root = struct(path = ""))
    asserts.equals(env, repr(abs(hash(source.path) + hash(repr(label)))), determine_output_hash(source, label))
    return unittest.end(env)

_configuration_independent_output_hash_test = unittest.make(_configuration_independent_output_hash_test_impl)

def utils_test_suite(name):
    unittest.suite(
        name,
        encode_label_as_crate_name_test,
        is_third_party_crate_test,
        substitutions_concatenate_test,
        encode_raw_string_test,
        decode_test,
        _proc_macro_without_dylib_test,
        _configuration_independent_output_hash_test,
    )
