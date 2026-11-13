fn main() {
    let out_dir = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    std::fs::write(out_dir.join("stamp-marker.txt"), "marker").unwrap();
    println!("cargo:rustc-env=STAMP={{STABLE_RUST_STAMP_TEST}}");
    println!("cargo:rustc-env=OUT_DIR={{STABLE_RUST_STAMP_UNRELATED}}");
}
