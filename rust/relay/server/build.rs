#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    use anyhow::Context as _;

    let manifest_dir =
        std::env::var("CARGO_MANIFEST_DIR").context("`CARGO_MANIFEST_DIR` not set")?;
    let root_dir = std::path::Path::new(&manifest_dir)
        .parent()
        .context("`CARGO_MANIFEST_DIR` has no parent directory")?
        .join("ebpf-turn-router");
    let root_dir = root_dir.to_str().context("path is not valid UTF-8")?;

    aya_build::build_ebpf(
        [aya_build::Package {
            name: "ebpf-turn-router",
            root_dir,
            ..Default::default()
        }],
        aya_build::Toolchain::Custom("nightly-2025-05-30"),
    )?;

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() {}
