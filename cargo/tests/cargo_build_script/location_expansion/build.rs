fn execpath(name: &str) -> String {
    let path = std::env::var(name).expect("Environment variable not set");
    assert!(std::path::Path::new(&path).is_absolute());
    assert!(std::path::Path::new(&path).exists());

    let normalized = path.replace('\\', "/");
    let (_, relative) = normalized
        .split_once("/bazel-out/")
        .expect("execpath does not contain bazel-out");
    format!("bazel-out/{}", relative)
}

fn main() {
    println!(
        "cargo:rustc-env=DATA_ROOTPATH={}",
        std::env::var("DATA_ROOTPATH").expect("Environment variable not set")
    );
    println!(
        "cargo:rustc-env=DATA_EXECPATH={}",
        execpath("DATA_EXECPATH")
    );
    println!(
        "cargo:rustc-env=TOOL_ROOTPATH={}",
        std::env::var("TOOL_ROOTPATH").expect("Environment variable not set")
    );
    println!(
        "cargo:rustc-env=TOOL_EXECPATH={}",
        execpath("TOOL_EXECPATH")
    );
}
