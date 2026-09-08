//! Photographs the tray menu of a GUI client wired to the mock Tunnel service.
//!
//! Everything it finds goes to the log, because a hosted runner's job log is
//! all there is to debug a capture with.

use crate::App;
use anyhow::{Context as _, Result, bail};
use std::{
    path::Path,
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{HWND, LPARAM, RECT, TRUE},
        Graphics::Gdi::{
            BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CreateCompatibleBitmap,
            CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, GetDIBits, HBITMAP,
            HDC, ReleaseDC, SRCCOPY, SelectObject,
        },
        UI::{
            Input::KeyboardAndMouse::{MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, mouse_event},
            WindowsAndMessaging::{
                EnumWindows, GetClassNameW, GetMenuItemCount, GetMenuItemRect, GetMenuStringW,
                GetSystemMetrics, GetWindowRect, HMENU, IsWindowVisible, MF_BYPOSITION,
                MN_GETHMENU, SM_CXSCREEN, SM_CYSCREEN, SPI_SETDROPSHADOW, SPI_SETMENUANIMATION,
                SPI_SETMENUFADE, SPI_SETSELECTIONFADE, SPI_SETUIEFFECTS, SPIF_SENDCHANGE,
                SPIF_UPDATEINIFILE, SendMessageW, SetCursorPos, SystemParametersInfoW,
            },
        },
    },
    core::BOOL,
};
use winreg::{RegKey, enums::HKEY_CURRENT_USER};

/// The resource whose submenu the capture expands.
const SUBMENU: &str = "Engineering wiki";

/// Popup menus are windows of this system class, one per open level.
const MENU_CLASS: &str = "#32768";

/// Photographs the tray menu with one resource's submenu expanded.
pub(crate) fn capture(app: &App, output: &Path) -> Result<()> {
    prepare_desktop()?;

    tracing::info!("=== tray screenshot: GUI starts against the mock Tunnel service ===");
    let gui = app
        .gui_command(&["--mock-tunnel", "--skip-portal-auth", "--no-error-dialog"])?
        .start()
        .context("Failed to start the GUI")?;

    let result = photograph(app, output);

    close_menu(app);
    if let Err(error) = gui.kill() {
        tracing::warn!("Failed to kill the GUI: {error:#}");
    }
    let _ = gui.wait();
    tracing::info!("=== tray screenshot complete ===");

    result
}

/// Prepares the desktop so the same pixels come out of every run.
///
/// Has to run before the client starts: it reads the theme at startup and
/// writing those keys broadcasts no settings change, so a client that started
/// first would keep the runner's original theme.
fn prepare_desktop() -> Result<()> {
    let width = unsafe { GetSystemMetrics(SM_CXSCREEN) };
    let height = unsafe { GetSystemMetrics(SM_CYSCREEN) };
    tracing::info!("Screen: {width}x{height}");

    // Animations, fades and shadows would make the capture timing-dependent.
    for (name, action) in [
        ("SPI_SETMENUANIMATION", SPI_SETMENUANIMATION),
        ("SPI_SETMENUFADE", SPI_SETMENUFADE),
        ("SPI_SETSELECTIONFADE", SPI_SETSELECTIONFADE),
        ("SPI_SETDROPSHADOW", SPI_SETDROPSHADOW),
        ("SPI_SETUIEFFECTS", SPI_SETUIEFFECTS),
    ] {
        // These actions carry the new setting in `pvParam` itself rather than
        // behind a pointer, so a null pointer is the `FALSE` we want.
        let result =
            unsafe { SystemParametersInfoW(action, 0, None, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE) };
        tracing::info!("{name} off: {result:?}");
    }

    let (personalize, _) = RegKey::predef(HKEY_CURRENT_USER)
        .create_subkey(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")
        .context("Failed to open the theme registry key")?;
    for name in ["AppsUseLightTheme", "SystemUsesLightTheme"] {
        personalize
            .set_value(name, &1u32)
            .with_context(|| format!("Failed to pin `{name}`"))?;
    }
    tracing::info!("Pinned the light theme");

    // The menu opens at the cursor, so park it where a menu always fits.
    unsafe { SetCursorPos(40, 40) }.context("Failed to park the cursor")?;

    Ok(())
}

fn photograph(app: &App, output: &Path) -> Result<()> {
    let (hmenu, item) = open_menu_at_submenu(app)?;
    click(hmenu, item)?;

    let menus = menu_windows();
    log_menu_windows("Submenu expanded", &menus);

    // Saved before the check, so a capture that went wrong can still be
    // inspected in the job's artifact.
    save(&menus, output)?;
    if menus.len() < 2 {
        bail!("The submenu did not open");
    }

    Ok(())
}

/// Opens the tray menu until it lists [`SUBMENU`], and returns that menu with
/// the item's index.
///
/// The menu only lists resources once the mock service has served them, so a
/// menu without the item is closed again and asked for anew.
fn open_menu_at_submenu(app: &App) -> Result<(HMENU, u32)> {
    let deadline = Instant::now() + Duration::from_secs(120);

    while Instant::now() < deadline {
        if !request(app, "open-tray-menu")? {
            tracing::info!("The running instance did not take the request; asking again");
            std::thread::sleep(Duration::from_millis(500));
            continue;
        }

        let menus = wait_for_menu();
        log_menu_windows("Menu open", &menus);
        let Some(first) = menus.first() else {
            tracing::info!("No menu is on screen; asking again");
            continue;
        };

        // The item rows hang off the `HMENU`, which the popup window only
        // hands out in response to `MN_GETHMENU`.
        let hmenu = unsafe { SendMessageW(first.hwnd, MN_GETHMENU, None, None) };
        let hmenu = HMENU(hmenu.0 as *mut _);
        if let Some(item) = menu_items(hmenu).iter().position(|text| text == SUBMENU) {
            return Ok((hmenu, item as u32));
        }

        tracing::info!("'{SUBMENU}' is not in the menu yet; closing it and asking again");
        close_menu(app);
        std::thread::sleep(Duration::from_millis(500));
    }

    bail!("'{SUBMENU}' did not appear in the tray menu within 120 seconds")
}

/// Waits for the popup menu to appear, then for it to stay.
///
/// An instance that was not ready opens the menu and closes it again, so the
/// settling delay is what tells the two apart.
fn wait_for_menu() -> Vec<MenuWindow> {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && menu_windows().is_empty() {
        std::thread::sleep(Duration::from_millis(250));
    }
    std::thread::sleep(Duration::from_millis(500));

    menu_windows()
}

/// Clicks the item at `index`, which expands its submenu.
fn click(hmenu: HMENU, index: u32) -> Result<()> {
    let mut rect = RECT::default();
    // Without an owner window the rect comes back in screen coordinates.
    unsafe { GetMenuItemRect(None, hmenu, index, &mut rect) }
        .context("Failed to locate the menu item")?;

    let x = (rect.left + rect.right) / 2;
    let y = (rect.top + rect.bottom) / 2;
    tracing::info!("Clicking '{SUBMENU}' (item {index}) at {x},{y}");
    unsafe { SetCursorPos(x, y) }.context("Failed to move the cursor onto the menu item")?;
    std::thread::sleep(Duration::from_millis(100));
    unsafe {
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    }
    std::thread::sleep(Duration::from_millis(500));

    Ok(())
}

/// Writes the pixels covered by `menus` to `output` as a PNG.
///
/// Each menu window is copied on its own, so the corners of their bounding box
/// that no menu covers stay transparent.
fn save(menus: &[MenuWindow], output: &Path) -> Result<()> {
    let Some(first) = menus.first() else {
        bail!("No menu is on screen, nothing to capture");
    };
    let bounds = menus.iter().fold(first.rect, |bounds, menu| RECT {
        left: bounds.left.min(menu.rect.left),
        top: bounds.top.min(menu.rect.top),
        right: bounds.right.max(menu.rect.right),
        bottom: bounds.bottom.max(menu.rect.bottom),
    });
    let width = bounds.right - bounds.left;
    let height = bounds.bottom - bounds.top;
    tracing::info!("Capturing {},{} {width}x{height}", bounds.left, bounds.top);

    let mut canvas = vec![0u8; (width * height * 4) as usize];
    for menu in menus {
        let pixels = screen_pixels(&menu.rect)?;
        let stride = ((menu.rect.right - menu.rect.left) * 4) as usize;
        let offset_x = menu.rect.left - bounds.left;
        let offset_y = menu.rect.top - bounds.top;

        for (y, row) in pixels.chunks_exact(stride).enumerate() {
            let start = (((y as i32 + offset_y) * width + offset_x) * 4) as usize;
            for (x, pixel) in row.as_chunks::<4>().0.iter().enumerate() {
                let target = start + x * 4;
                canvas[target] = pixel[2];
                canvas[target + 1] = pixel[1];
                canvas[target + 2] = pixel[0];
                // The screen has no alpha channel, so paint the copy opaque.
                canvas[target + 3] = u8::MAX;
            }
        }
    }

    if let Some(directory) = output.parent() {
        std::fs::create_dir_all(directory)
            .with_context(|| format!("Failed to create `{}`", directory.display()))?;
    }
    let file = std::fs::File::create(output)
        .with_context(|| format!("Failed to create `{}`", output.display()))?;
    let mut encoder = png::Encoder::new(file, width as u32, height as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().context("Failed to write the PNG")?;
    writer
        .write_image_data(&canvas)
        .context("Failed to write the PNG pixels")?;
    writer.finish().context("Failed to finish the PNG")?;
    tracing::info!("Saved {}", output.display());

    Ok(())
}

/// Copies the screen pixels under `rect` into a top-down 32bpp BGRA buffer.
fn screen_pixels(rect: &RECT) -> Result<Vec<u8>> {
    let width = rect.right - rect.left;
    let height = rect.bottom - rect.top;

    let screen = unsafe { GetDC(None) };
    if screen.is_invalid() {
        bail!("`GetDC` returned no screen device context");
    }
    let memory = unsafe { CreateCompatibleDC(Some(screen)) };
    let bitmap = unsafe { CreateCompatibleBitmap(screen, width, height) };

    let pixels = read_screen(screen, memory, bitmap, rect, width, height);

    unsafe {
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(memory);
        ReleaseDC(None, screen);
    }

    pixels
}

fn read_screen(
    screen: HDC,
    memory: HDC,
    bitmap: HBITMAP,
    rect: &RECT,
    width: i32,
    height: i32,
) -> Result<Vec<u8>> {
    if memory.is_invalid() || bitmap.is_invalid() {
        bail!("Failed to create a {width}x{height} off-screen bitmap");
    }

    let previous = unsafe { SelectObject(memory, bitmap.into()) };
    let blit = unsafe {
        BitBlt(
            memory,
            0,
            0,
            width,
            height,
            Some(screen),
            rect.left,
            rect.top,
            SRCCOPY,
        )
    };
    // `GetDIBits` refuses a bitmap that is still selected into a device context.
    unsafe { SelectObject(memory, previous) };
    blit.context("Failed to copy the screen region")?;

    let mut info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            // Negative asks for a top-down DIB, so the first row read is the
            // top one and the canvas comes out the right way up.
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut pixels = vec![0u8; (width * height * 4) as usize];
    let rows = unsafe {
        GetDIBits(
            memory,
            bitmap,
            0,
            height as u32,
            Some(pixels.as_mut_ptr().cast()),
            &mut info,
            DIB_RGB_COLORS,
        )
    };
    if rows != height {
        bail!("`GetDIBits` read {rows} of {height} rows");
    }

    Ok(pixels)
}

/// Asks the already running instance to run `command`, and reports whether it
/// took the request.
fn request(app: &App, command: &str) -> Result<bool> {
    tracing::info!("Asking the running instance to {command}");

    let request = app
        .gui_command(&[command])?
        .start()
        .with_context(|| format!("Failed to spawn `{command}`"))?;
    let Some(status) = request
        .wait_timeout(Duration::from_secs(30))
        .with_context(|| format!("Failed to wait for `{command}`"))?
    else {
        request.kill().context("Failed to kill the request")?;
        let _ = request.wait();
        bail!("`{command}` never exited");
    };
    tracing::info!("`{command}` exited with {status:?}");

    Ok(status.success())
}

fn close_menu(app: &App) {
    if let Err(error) = request(app, "close-tray-menu") {
        tracing::warn!("Failed to close the tray menu: {error:#}");
    }
}

/// Returns the text of every item in `hmenu`, in order.
fn menu_items(hmenu: HMENU) -> Vec<String> {
    let count = unsafe { GetMenuItemCount(Some(hmenu)) };
    tracing::info!("The menu has {count} items:");

    (0..count.max(0))
        .map(|index| {
            let mut text = [0u16; 256];
            let len = unsafe {
                GetMenuStringW(
                    hmenu,
                    index as u32,
                    Some(text.as_mut_slice()),
                    MF_BYPOSITION,
                )
            };
            let text = String::from_utf16_lossy(&text[..len.max(0) as usize]).replace('&', "");
            tracing::info!("  [{index}] '{text}'");

            text
        })
        .collect()
}

/// Returns the visible popup menus on screen, in Z-order.
fn menu_windows() -> Vec<MenuWindow> {
    let mut hwnds = Vec::new();

    // SAFETY: `hwnds` outlives the callback, which only runs during this call.
    // The status goes unchecked because an empty list is what tells us no menu
    // is open, which is not an error here.
    let _ = unsafe {
        EnumWindows(
            Some(collect_menu_window),
            LPARAM(&mut hwnds as *mut Vec<HWND> as isize),
        )
    };

    hwnds
        .into_iter()
        .filter_map(|hwnd| {
            let mut rect = RECT::default();
            // A menu can be destroyed between the enumeration and this query.
            unsafe { GetWindowRect(hwnd, &mut rect) }.ok()?;

            Some(MenuWindow { hwnd, rect })
        })
        .collect()
}

unsafe extern "system" fn collect_menu_window(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let mut class = [0u16; 32];
    let len = unsafe { GetClassNameW(hwnd, class.as_mut_slice()) };
    let class = String::from_utf16_lossy(&class[..len.max(0) as usize]);

    if class == MENU_CLASS && unsafe { IsWindowVisible(hwnd) }.as_bool() {
        // SAFETY: `menu_windows` passes a pointer to a live `Vec<HWND>`.
        unsafe { &mut *(lparam.0 as *mut Vec<HWND>) }.push(hwnd);
    }

    TRUE
}

fn log_menu_windows(label: &str, menus: &[MenuWindow]) {
    tracing::info!("{label}: {} menu window(s)", menus.len());

    for MenuWindow { hwnd, rect } in menus {
        tracing::info!("  hwnd={:?} {rect:?}", hwnd.0);
    }
}

struct MenuWindow {
    hwnd: HWND,
    rect: RECT,
}
