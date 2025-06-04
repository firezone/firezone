// Manually vendored from https://github.com/itchyny/uptime-rs/blob/e6e31f4aa69b057d0610c20f8f2b5f8f0724decb/src/lib.rs and https://github.com/itchyny/uptime-rs/blob/e6e31f4aa69b057d0610c20f8f2b5f8f0724decb/tests/lib.rs

/*
The MIT License (MIT)

Copyright (c) 2017-2023 itchyny <https://github.com/itchyny>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

use std::time::Duration;

#[cfg(target_os = "linux")]
pub fn get() -> Option<Duration> {
    let mut info: libc::sysinfo = unsafe { std::mem::zeroed() };
    let ret = unsafe { libc::sysinfo(&mut info) };
    if ret == 0 {
        Some(Duration::from_secs(info.uptime as u64))
    } else {
        None
    }
}

#[cfg(target_os = "windows")]
// `Result` is needed to match other platforms' signatures
#[expect(clippy::unnecessary_wraps)]
pub fn get() -> Option<Duration> {
    let ret: u64 = unsafe { windows::Win32::System::SystemInformation::GetTickCount64() };
    Some(Duration::from_millis(ret))
}

#[cfg(target_os = "macos")]
pub fn get() -> Option<Duration> {
    // TODO: This is stubbed on macOS for now so that mac developers can help out on the Tauri UI.
    None
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_uptime_get() {
        assert!(super::get().is_some());
    }
}
