// This hides the console window but prevents Cygwin from showing stderr/stdout and breaks Ctrl+C
// #![windows_subsystem = "windows"]

use std::sync::Mutex;

use native_windows_derive as nwd;
use native_windows_gui as nwg;

use nwd::NwgUi;
use nwg::NativeUi;

#[derive(Default)]
struct AppState {
    signed_in: bool,
}

#[derive(Default, NwgUi)]
pub struct SystemTray {
    app_state: Mutex<AppState>,

    #[nwg_control]
    window: nwg::MessageWindow,

    #[nwg_resource(source_file: Some("./favicon.ico"))]
    icon: nwg::Icon,

    #[nwg_control(icon: Some(&data.icon), tip: Some("Firezone Client"))]
    #[nwg_events(MousePressLeftUp: [SystemTray::show_menu], OnContextMenu: [SystemTray::show_menu])]
    tray: nwg::TrayNotification,

    // Tray menu shown when signed out
    #[nwg_control(parent: window, popup: true)]
    tray_menu_signed_out: nwg::Menu,

    #[nwg_control(parent: tray_menu_signed_out, text: "Sign In")]
    #[nwg_events(OnMenuItemSelected: [SystemTray::sign_in])]
    tray_sign_in: nwg::MenuItem,

    #[nwg_control(parent: tray_menu_signed_out)]
    tray_sep_1: nwg::MenuSeparator,

    #[nwg_control(parent: tray_menu_signed_out, text: "About")]
    #[nwg_events(OnMenuItemSelected: [SystemTray::about])]
    tray_about_1: nwg::MenuItem,

    #[nwg_control(parent: tray_menu_signed_out, text: "Settings")]
    #[nwg_events(OnMenuItemSelected: [SystemTray::settings])]
    tray_settings_1: nwg::MenuItem,

    #[nwg_control(parent: tray_menu_signed_out, text: "Quit Firezone\tCtrl+Q")]
    #[nwg_events(OnMenuItemSelected: [SystemTray::exit])]
    tray_quit_1: nwg::MenuItem,

    // Tray menu shown when signed in
    #[nwg_control(parent: window, popup: true)]
    tray_menu_signed_in: nwg::Menu,

    #[nwg_control(parent: tray_menu_signed_in, text: "Signed in as me@example.com")]
    tray_signed_in_as: nwg::MenuItem,

    #[nwg_control(parent: tray_menu_signed_in, text: "Sign out")]
    #[nwg_events(OnMenuItemSelected: [SystemTray::sign_out])]
    tray_sign_out: nwg::MenuItem,

    #[nwg_control(parent: tray_menu_signed_in)]
    tray_sep_2: nwg::MenuSeparator,

    #[nwg_control(parent: tray_menu_signed_in, text: "RESOURCES")]
    tray_resources: nwg::MenuItem,

    #[nwg_control(parent: tray_menu_signed_in)]
    tray_sep_3: nwg::MenuSeparator,

    #[nwg_control(parent: tray_menu_signed_in, text: "About")]
    #[nwg_events(OnMenuItemSelected: [SystemTray::about])]
    tray_about_2: nwg::MenuItem,

    #[nwg_control(parent: tray_menu_signed_in, text: "Settings")]
    #[nwg_events(OnMenuItemSelected: [SystemTray::settings])]
    tray_settings_2: nwg::MenuItem,

    #[nwg_control(parent: tray_menu_signed_in, text: "Quit Firezone\tCtrl+Q")]
    #[nwg_events(OnMenuItemSelected: [SystemTray::exit])]
    tray_quit_2: nwg::MenuItem,
}

impl SystemTray {
    // Writing the whole constructor would be hard, so do this for now

    fn init(&self) {
        self.update_tray_state();
    }

    fn show_menu(&self) {
        let (x, y) = nwg::GlobalCursor::position();

        let app = self.app_state.lock().unwrap();
        if app.signed_in {
            self.tray_menu_signed_in.popup(x, y);
        } else {
            self.tray_menu_signed_out.popup(x, y);
        }
    }

    fn update_tray_state(&self) {
        self.tray_signed_in_as.set_enabled(false);
    }

    fn sign_in(&self) {
        {
            let mut app = self.app_state.lock().unwrap();
            app.signed_in = true;
        }
        self.update_tray_state();
    }

    fn sign_out(&self) {
        {
            let mut app = self.app_state.lock().unwrap();
            app.signed_in = false;
        }
        self.update_tray_state();
    }

    fn about(&self) {
        nwg::simple_message("Firezone Client", "https://www.firezone.dev/");
    }

    fn settings(&self) {
        let flags = nwg::TrayNotificationFlags::USER_ICON | nwg::TrayNotificationFlags::LARGE_ICON;
        self.tray.show(
            "Firezone client",
            Some("Welcome to Firezone"),
            Some(flags),
            Some(&self.icon),
        );
    }

    fn exit(&self) {
        nwg::stop_thread_dispatch();
    }
}

fn main() {
    nwg::init().unwrap();
    let ui = SystemTray::build_ui(Default::default()).unwrap();
    ui.init();
    nwg::dispatch_thread_events();
}
