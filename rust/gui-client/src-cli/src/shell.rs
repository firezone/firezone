//! Which shell launched this process, so the commands shown to the user are ones it can run.

use windows::Win32::Foundation::CloseHandle;
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shell {
    PowerShell,
    Cmd,
}

impl Shell {
    /// The shell that launched this process.
    ///
    /// PowerShell is assumed whenever the parent cannot be identified: Windows
    /// Terminal opens it by default, and `<` redirection, which only cmd.exe
    /// needs, is the form that fails there.
    pub fn detect() -> Self {
        parent_exe_name()
            .map(|name| Self::from_exe_name(&name))
            .unwrap_or(Self::PowerShell)
    }

    fn from_exe_name(exe_name: &str) -> Self {
        if exe_name.eq_ignore_ascii_case("cmd.exe") {
            return Self::Cmd;
        }

        Self::PowerShell
    }
}

/// The file name of the executable of this process's parent.
fn parent_exe_name() -> Option<String> {
    let processes = processes()?;
    let own_pid = std::process::id();

    let parent_pid = processes
        .iter()
        .find(|process| process.th32ProcessID == own_pid)?
        .th32ParentProcessID;
    let parent = processes
        .iter()
        .find(|process| process.th32ProcessID == parent_pid)?;

    let exe_file = &parent.szExeFile;
    let len = exe_file
        .iter()
        .position(|&c| c == 0)
        .unwrap_or(exe_file.len());

    Some(String::from_utf16_lossy(&exe_file[..len]))
}

fn processes() -> Option<Vec<PROCESSENTRY32W>> {
    // SAFETY: No pointers are passed; the returned handle is closed below.
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }.ok()?;

    let mut processes = Vec::new();
    let mut entry = PROCESSENTRY32W {
        dwSize: size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };

    // SAFETY: `snapshot` is an open snapshot handle and `entry` a live
    // `PROCESSENTRY32W` with `dwSize` set, as the call requires.
    let mut found = unsafe { Process32FirstW(snapshot, &mut entry) };

    while found.is_ok() {
        processes.push(entry);

        // SAFETY: As above.
        found = unsafe { Process32NextW(snapshot, &mut entry) };
    }

    // SAFETY: `snapshot` is open and not used again.
    let _ = unsafe { CloseHandle(snapshot) };

    Some(processes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmd_by_any_casing() {
        assert_eq!(Shell::from_exe_name("cmd.exe"), Shell::Cmd);
        assert_eq!(Shell::from_exe_name("CMD.EXE"), Shell::Cmd);
    }

    #[test]
    fn anything_else_is_powershell() {
        assert_eq!(Shell::from_exe_name("pwsh.exe"), Shell::PowerShell);
        assert_eq!(Shell::from_exe_name("powershell.exe"), Shell::PowerShell);
        assert_eq!(Shell::from_exe_name("explorer.exe"), Shell::PowerShell);
    }
}
