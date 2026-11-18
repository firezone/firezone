//! The commit SHA a binary was built from, stamped in after linking by `mise run //rust:patch-git-sha`.

/// The 17-byte `firezone-git-sha:` marker followed by a 40-character SHA, all zeros until stamped.
///
/// The stamping task locates the marker by its bytes, so it must appear exactly once in a binary.
#[used]
static PLACEHOLDER: [u8; 57] = *b"firezone-git-sha:0000000000000000000000000000000000000000";

/// Returns the commit SHA stamped into this binary, or [`None`] if it was not stamped.
pub fn git_sha() -> Option<&'static str> {
    // Keeps the optimizer from folding the zeros into a constant, as the bytes change after linking.
    let placeholder = std::hint::black_box(&PLACEHOLDER);
    let sha = std::str::from_utf8(&placeholder[17..]).ok()?;

    sha.bytes().any(|b| b != b'0').then_some(sha)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unstamped_binary_has_no_git_sha() {
        assert_eq!(git_sha(), None);
    }
}
