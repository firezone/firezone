// Sample code from https://github.com/microsoft/windows-rs/blob/0.52.0/crates/samples/windows/create_window/src/main.rs

use windows::{
    core::*,
    Win32::{
        Foundation::*,
        Graphics::Gdi::ValidateRect,
        System::LibraryLoader::GetModuleHandleA,
        UI::{Shell::*, WindowsAndMessaging::*},
    },
};

fn main() -> Result<()> {
    unsafe {
        let instance = GetModuleHandleA(None)?;
        debug_assert!(instance.0 != 0);

        let window_class = s!("window");

        let wc = WNDCLASSA {
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            hInstance: instance.into(),
            lpszClassName: window_class,

            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(wndproc),
            ..Default::default()
        };

        let atom = RegisterClassA(&wc);
        debug_assert!(atom != 0);

        let window = CreateWindowExA(
            WINDOW_EX_STYLE::default(),
            window_class,
            s!("This is a sample window"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            None,
            None,
            instance,
            None,
        );

        // Create tray icon

        let _notify_icon_data = NOTIFYICONDATAA {
            cbSize: std::mem::size_of::<NOTIFYICONDATAA>().try_into().unwrap(),
            hWnd: window,
            uID: 0,
            uFlags: NOTIFY_ICON_DATA_FLAGS(0),
            uCallbackMessage: 0,
            hIcon: HICON(0),
            szTip: [0; 128],
            dwState: NOTIFY_ICON_STATE(0),
            dwStateMask: 0,
            szInfo: [0; 256],
            Anonymous: NOTIFYICONDATAA_0 { uVersion: 0 },
            szInfoTitle: [0; 64],
            dwInfoFlags: NOTIFY_ICON_INFOTIP_FLAGS(0),
            guidItem: GUID::new().unwrap(),
            hBalloonIcon: HICON(0),
        };

        let mut message = MSG::default();

        while GetMessageA(&mut message, None, 0, 0).into() {
            DispatchMessageA(&message);
        }

        Ok(())
    }
}

extern "system" fn wndproc(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        match message {
            WM_PAINT => {
                println!("WM_PAINT");
                ValidateRect(window, None);
                LRESULT(0)
            }
            WM_DESTROY => {
                println!("WM_DESTROY");
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcA(window, message, wparam, lparam),
        }
    }
}
