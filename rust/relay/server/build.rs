#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    use anyhow::Context as _;
    use aya_build::cargo_metadata::{MetadataCommand, Package};

    // Build scripts don't receive feature cfgs, only the `CARGO_FEATURE_<name>`
    // env var for each activated feature. When the `ebpf` feature is disabled we
    // skip compiling the eBPF program entirely, which avoids the dependency on the
    // pinned nightly toolchain and `bpf-linker`.
    if std::env::var_os("CARGO_FEATURE_EBPF").is_none() {
        return Ok(());
    }

    let package = MetadataCommand::new()
        .no_deps()
        .exec()
        .context("MetadataCommand::exec")?
        .packages
        .into_iter()
        .find(|Package { name, .. }| name.as_str() == "ebpf-turn-router")
        .context("`ebpf-turn-router` package not found")?;

    aya_build::build_ebpf(
        [package],
        aya_build::Toolchain::Custom("nightly-2025-05-30"),
    )?;

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() {}
