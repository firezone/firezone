fn main() -> anyhow::Result<()> {
    // Skip tauri-build's default Common-Controls manifest: we embed
    // our own SXS / fusion manifest below — only into `Firezone.exe`,
    // not into the tunnel-service or register-sparse binaries (SCM-
    // launched services with an embedded `<msix>` identity claim
    // hang on startup, and the helper has no use for identity).
    let win = tauri_build::WindowsAttributes::new_without_app_manifest();
    let attr = tauri_build::Attributes::new().windows_attributes(win);
    tauri_build::try_build(attr)?;

    #[cfg(target_os = "windows")]
    {
        embed_resource::compile_for(
            "win_files/Firezone.exe.manifest.rc",
            ["firezone-gui-client"],
            embed_resource::NONE,
        )
        .manifest_required()?;

        println!("cargo:rerun-if-changed=win_files/Firezone.exe.manifest");
        println!("cargo:rerun-if-changed=win_files/Firezone.exe.manifest.rc");
    }

    println!("cargo:rerun-if-changed=../website/public/policy-templates/windows/firezone.admx");

    Ok(())
}
