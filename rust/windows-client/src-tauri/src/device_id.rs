use smbioslib::SMBiosSystemInformation as SysInfo;

pub fn get() -> String {
    // TODO: Is the suggested SHA256 only intended to make the device ID fixed-length, or is it supposed to obfuscate the ID too? If so, we could add a pepper to defeat rainbow tables.

    get_from_bios().unwrap_or_else(|| {
        tracing::warn!("Making a random device ID");
        uuid::Uuid::new_v4().to_string()
    })
}

fn get_from_bios() -> Option<String> {
    let data = smbioslib::table_load_from_device().ok()?;
    if let Some(uuid) = data.find_map(|sys_info: SysInfo| sys_info.uuid()) {
        tracing::info!("smbioslib got UUID");
        Some(uuid.to_string())
    } else {
        tracing::warn!("smbioslib couldn't find UUID");
        None
    }
}
