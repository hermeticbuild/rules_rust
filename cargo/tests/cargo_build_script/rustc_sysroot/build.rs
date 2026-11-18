//! Checks the `RUSTC` a build script is given: run without `--sysroot`, as
//! build scripts that probe the compiler do, it uses the sysroot the crate is
//! compiled with and finds the standard library for `TARGET`.

use std::env;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

fn main() {
    let rustc = env::var("RUSTC").expect("`cargo_build_script` sets `RUSTC`");
    let target = env::var("TARGET").expect("`cargo_build_script` sets `TARGET`");
    let out_dir = env::var("OUT_DIR").expect("`cargo_build_script` sets `OUT_DIR`");
    let rustflags = env::var("CARGO_ENCODED_RUSTFLAGS")
        .expect("`cargo_build_script` sets `CARGO_ENCODED_RUSTFLAGS`");
    let sysroot = rustflags
        .split('\x1f')
        .find_map(|flag| flag.strip_prefix("--sysroot="))
        .expect("`CARGO_ENCODED_RUSTFLAGS` names the sysroot");

    let output = Command::new(&rustc)
        .args(["--print", "sysroot"])
        .output()
        .unwrap_or_else(|err| panic!("failed to run `{rustc}`: {err}"));
    assert!(output.status.success(), "`{rustc} --print sysroot` failed");
    let printed = String::from_utf8(output.stdout).unwrap();
    assert_eq!(
        Path::new(printed.trim()),
        Path::new(sysroot),
        "`$RUSTC` should use the sysroot the crate is compiled with",
    );

    let mut child = Command::new(&rustc)
        .args(["--crate-type=lib", "--emit=metadata", "--crate-name=probe"])
        .args(["--target", &target, "--out-dir", &out_dir, "-"])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap_or_else(|err| panic!("failed to run `{rustc}`: {err}"));
    writeln!(
        child.stdin.take().unwrap(),
        "pub fn f() -> String {{ String::new() }}"
    )
    .unwrap();
    assert!(
        child.wait().unwrap().success(),
        "`$RUSTC` can't find the standard library for `{target}`"
    );

    println!("cargo:rustc-env=RUSTC_FOUND_STD={target}");
}
