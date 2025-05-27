fn main() -> anyhow::Result<()> {
    let win = tauri_build::WindowsAttributes::new();
    let attr = tauri_build::Attributes::new().windows_attributes(win);
    tauri_build::try_build(attr)?;

    println!("cargo:rerun-if-changed=../website/public/policy-templates/windows/firezone.admx");

    Ok(())
}
