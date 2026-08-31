pub fn from_lib() -> &'static str {
    env!("GREETING")
}

pub fn env_file() -> &'static str {
    include_str!(env!("RUSTC_ENV_PATH"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn verify_from_lib() {
        assert_eq!(super::from_lib(), "Howdy");
    }

    #[test]
    fn verify_from_test() {
        assert_eq!(env!("GREETING"), "Howdy");
    }

    #[test]
    fn verify_env_path() {
        assert!(super::env_file().contains("GREETING=Howdy"));
    }
}
