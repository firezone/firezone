#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    use anyhow::Context as _;
    use aya_build::cargo_metadata::{MetadataCommand, Package};

    let package = MetadataCommand::new()
        .no_deps()
        .exec()
        .context("MetadataCommand::exec")?
        .packages
        .into_iter()
        .find(|Package { name, .. }| name == "ebpf-turn-router")
        .context("`ebpf-turn-router` package not found")?;

    aya_build::build_ebpf(
        [package],
        aya_build::Toolchain::Custom("+nightly-2024-12-13"),
    )?;

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() {}
