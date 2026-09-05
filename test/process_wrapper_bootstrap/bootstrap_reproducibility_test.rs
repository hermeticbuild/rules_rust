//! Check the metadata of tinyjson compiled with the bootstrap process wrapper.

#[test]
fn bootstrap_tinyjson_does_not_embed_execution_paths() {
    let rfiles = runfiles::Runfiles::create().unwrap();
    let rlocation = std::env::var("BOOTSTRAP_TINYJSON_RLOCATIONPATH").unwrap();
    let artifact = runfiles::rlocation!(rfiles, rlocation.as_str()).unwrap();
    let bytes = std::fs::read(&artifact).unwrap();

    for prefix in ["/execroot/", "\\execroot\\", "/sandbox/", "\\sandbox\\"] {
        assert!(
            !bytes
                .windows(prefix.len())
                .any(|part| part == prefix.as_bytes()),
            "{} contains an unremapped execution path ({prefix})",
            artifact.display(),
        );
    }
}
