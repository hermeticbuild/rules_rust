fn main() {
    assert!(cfg!(build_script_only));
    assert!(cfg!(target_feature = "build_script_only"));
    assert_eq!(std::env::var("TARGET").unwrap(), "x86_64-pc-windows-msvc");
    let features = std::env::var("CARGO_CFG_TARGET_FEATURE").unwrap();
    let features: Vec<_> = features.split(',').collect();
    assert!(features.contains(&"crt-static"), "{features:?}");
    // The last target-cpu flag wins; arguments must retain their order.
    assert!(features.contains(&"avx2"), "{features:?}");
    // Exec and crate-type flags must not enter this configuration-wide query.
    assert!(!features.contains(&"avx512f"), "{features:?}");
    assert!(!features.contains(&"build_script_only"), "{features:?}");
}
