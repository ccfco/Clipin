uniffi::setup_scaffolding!();

#[uniffi::export]
fn hello_from_rust() -> String {
    "Hello from Clipin Core! 🚀".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hello() {
        let result = hello_from_rust();
        assert!(result.contains("Clipin"));
    }
}
