pub fn serial() -> Option<String> {
    const DEFAULT_SERIAL: &str = "123456789";
    let data = smbioslib::table_load_from_device().ok()?;

    let serial = data.find_map(|sys_info: smbioslib::SMBiosSystemInformation| {
        sys_info.serial_number().to_utf8_lossy()
    })?;

    if serial == DEFAULT_SERIAL {
        return None;
    }

    Some(serial)
}

pub fn uuid() -> Option<String> {
    let data = smbioslib::table_load_from_device().ok()?;

    let uuid = data.find_map(|sys_info: smbioslib::SMBiosSystemInformation| sys_info.uuid());

    uuid?.to_string().into()
}
