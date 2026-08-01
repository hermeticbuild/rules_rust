#[test]
pub fn test_data_rootpath() {
    assert_eq!(
        "cargo/tests/cargo_build_script/location_expansion/target_data.txt",
        env!("DATA_ROOTPATH")
    );
}

#[test]
pub fn test_tool_rootpath() {
    assert_eq!(
        "cargo/tests/cargo_build_script/location_expansion/exec_data.txt",
        env!("TOOL_ROOTPATH")
    );
}

#[test]
pub fn test_execpath() {
    let data_execpath = env!("DATA_EXECPATH");
    let tool_execpath = env!("TOOL_EXECPATH");
    let (data_cfg, data_short_path) = data_execpath
        .split_once("/bin/")
        .unwrap_or_else(|| panic!("Failed to find bin in {}", data_execpath));
    let (tool_cfg, tool_short_path) = tool_execpath
        .split_once("/bin/")
        .unwrap_or_else(|| panic!("Failed to find bin in {}", tool_execpath));

    assert_ne!(
        data_cfg, tool_cfg,
        "Data and tools should not be from the same configuration."
    );

    assert_eq!(
        data_short_path,
        "cargo/tests/cargo_build_script/location_expansion/target_data.txt"
    );
    assert_eq!(
        tool_short_path,
        "cargo/tests/cargo_build_script/location_expansion/exec_data.txt"
    );
}
