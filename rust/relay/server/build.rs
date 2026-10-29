#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    use anyhow::Context as _;

    let manifest_dir =
        std::env::var("CARGO_MANIFEST_DIR").context("`CARGO_MANIFEST_DIR` not set")?;
    let relay_dir = std::path::Path::new(&manifest_dir)
        .parent()
        .context("`CARGO_MANIFEST_DIR` has no parent directory")?;
    let root_dir = relay_dir.join("ebpf-turn-router");
    let root_dir = root_dir.to_str().context("path is not valid UTF-8")?;

    // `aya_build` only watches the eBPF crate itself, but its code also comes from our other crates.
    println!(
        "cargo::rerun-if-changed={}",
        relay_dir.join("ebpf-shared").display()
    );
    println!(
        "cargo::rerun-if-changed={}",
        relay_dir
            .join("../libs/incremental-inet-checksum")
            .display()
    );

    aya_build::build_ebpf(
        [aya_build::Package {
            name: "ebpf-turn-router",
            root_dir,
            ..Default::default()
        }],
        aya_build::Toolchain::Custom("nightly-2026-10-17"),
    )?;

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() {}
