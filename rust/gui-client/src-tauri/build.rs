fn main() -> anyhow::Result<()> {
    // Skip tauri-build's default Common-Controls manifest: we embed
    // our own per-binary manifests below (Tauri's machinery embeds
    // into *every* binary in the crate, which is wrong here because
    // `Firezone.exe` and `firezone-client-tunnel.exe` need
    // different `applicationId`s in the `<msix>` element).
    let win = tauri_build::WindowsAttributes::new_without_app_manifest();
    let attr = tauri_build::Attributes::new().windows_attributes(win);
    tauri_build::try_build(attr)?;

    #[cfg(target_os = "windows")]
    {
        // Embed the side-by-side / fusion manifest into each EXE
        // that needs to claim package identity from our sparse
        // MSIX. `Executable=` paths in `AppxManifest.xml` aren't
        // enough on their own — the kernel matches by the
        // `<msix>` element in the EXE's own manifest.
        embed_resource::compile_for(
            "win_files/Firezone.exe.manifest.rc",
            ["firezone-gui-client"],
            embed_resource::NONE,
        )
        .manifest_required()?;
        embed_resource::compile_for(
            "win_files/firezone-client-tunnel.exe.manifest.rc",
            ["firezone-client-tunnel"],
            embed_resource::NONE,
        )
        .manifest_required()?;

        println!("cargo:rerun-if-changed=win_files/Firezone.exe.manifest");
        println!("cargo:rerun-if-changed=win_files/Firezone.exe.manifest.rc");
        println!("cargo:rerun-if-changed=win_files/firezone-client-tunnel.exe.manifest");
        println!("cargo:rerun-if-changed=win_files/firezone-client-tunnel.exe.manifest.rc");
    }

    println!("cargo:rerun-if-changed=../website/public/policy-templates/windows/firezone.admx");

    Ok(())
}
