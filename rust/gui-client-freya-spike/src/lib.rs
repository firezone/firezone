use freya::prelude::*;
use tokio::sync::mpsc;

pub mod components;
mod pages;
pub mod theme;

use components::{Icon, icon, pal, text};

pub const SANS: &str = "Roboto";
pub const MONO: &str = "Roboto Mono";
pub const FONTS: [(&str, &[u8]); 5] = [
    (SANS, include_bytes!("../assets/roboto-400.ttf")),
    (SANS, include_bytes!("../assets/roboto-500.ttf")),
    (SANS, include_bytes!("../assets/roboto-600.ttf")),
    (SANS, include_bytes!("../assets/roboto-700.ttf")),
    (MONO, include_bytes!("../assets/roboto-mono-400.ttf")),
];

// The view models of `generated/bindings.ts`.

#[derive(Clone, Debug, PartialEq)]
pub enum Session {
    SignedOut,
    Loading,
    SignedIn { account_slug: String, actor_name: String },
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ControlPlane {
    CloudUs,
    CloudEu,
    #[default]
    Custom,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SignInSettings {
    pub account_slug: String,
    pub control_plane: ControlPlane,
    pub auth_url: String,
    pub api_url: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GeneralSettings {
    pub start_minimized: bool,
    pub start_on_login: bool,
    pub start_on_login_is_managed: bool,
    pub connect_on_start: bool,
    pub connect_on_start_is_managed: bool,
    pub account_slug: String,
    pub account_slug_is_managed: bool,
    pub control_plane: ControlPlane,
    pub auth_url: String,
    pub auth_url_is_managed: bool,
    pub api_url: String,
    pub api_url_is_managed: bool,
    pub custom_auth_url: String,
    pub custom_api_url: String,
    pub signed_in_with: Option<SignInSettings>,
}

impl Default for GeneralSettings {
    fn default() -> Self {
        Self {
            start_minimized: true,
            start_on_login: false,
            start_on_login_is_managed: false,
            connect_on_start: false,
            connect_on_start_is_managed: false,
            account_slug: String::new(),
            account_slug_is_managed: false,
            control_plane: ControlPlane::Custom,
            auth_url: String::new(),
            auth_url_is_managed: false,
            api_url: String::new(),
            api_url_is_managed: false,
            custom_auth_url: String::new(),
            custom_api_url: String::new(),
            signed_in_with: None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct LogFilter {
    pub log_filter: String,
    pub log_filter_is_managed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FileCount {
    pub bytes: u64,
    pub files: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CertField {
    pub label: String,
    pub value: Option<String>,
    pub problem: Option<String>,
}

/// What the Controller pushes into the UI. `None` is a view model it has not sent yet.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ViewModel {
    pub session: Option<Session>,
    pub general_settings: Option<GeneralSettings>,
    pub log_filter: Option<LogFilter>,
    pub log_count: Option<FileCount>,
    pub certificate: Option<Vec<CertField>>,
}

/// The partial `ClientSettingsForm`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SettingsChange {
    pub start_minimized: Option<bool>,
    pub start_on_login: Option<bool>,
    pub connect_on_start: Option<bool>,
    pub account_slug: Option<String>,
    pub control_plane: Option<ControlPlane>,
    pub auth_url: Option<String>,
    pub api_url: Option<String>,
}

/// What the UI sends to the Controller.
#[derive(Clone, Debug, PartialEq)]
pub enum Request {
    SignIn,
    SignOut,
    ApplySettings(SettingsChange),
    ResetSettings,
    ApplyLogFilter(String),
    ExportLogs,
    ClearLogs,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Page {
    Overview,
    Settings,
    DeviceTrust,
    Diagnostics,
    About,
    ColorPalette,
}

/// Root context shared by every window: the view model and the request sender.
#[derive(Clone)]
pub struct Bridge {
    pub vm: State<ViewModel>,
    pub requests: mpsc::UnboundedSender<Request>,
    pub dark: bool,
    pub start_page: Page,
}

impl Bridge {
    pub fn send(&self, request: Request) {
        let _ = self.requests.send(request);
    }
}

/// UI side of the glue: apply view-model updates from the Controller to the global state.
pub async fn apply_updates(mut updates: mpsc::UnboundedReceiver<ViewModel>, mut vm: State<ViewModel>) {
    while let Some(new) = updates.recv().await {
        vm.set(new);
    }
}

pub fn app() -> impl IntoElement {
    let bridge = use_consume::<Bridge>();
    let p = pal();
    let page = use_state(|| bridge.start_page);
    let vm = bridge.vm.read().clone();
    let device_trust = vm.certificate.is_some();
    let current = match page() {
        Page::DeviceTrust if vm.certificate.is_none() => Page::Overview,
        page => page,
    };
    let title = match current {
        Page::Overview => "Firezone",
        Page::Settings => "Settings",
        Page::DeviceTrust => "Device Trust",
        Page::Diagnostics => "Diagnostics",
        Page::About => "About",
        Page::ColorPalette => "Colour Palette",
    };
    let content = match current {
        Page::Overview => pages::Overview(vm.session).into_element(),
        Page::Settings => pages::GeneralSettingsPage(vm.general_settings.unwrap_or_default()).into_element(),
        Page::DeviceTrust => pages::device_trust(&vm.certificate.unwrap_or_default()).into_element(),
        Page::Diagnostics => pages::Diagnostics { log_count: vm.log_count, log_filter: vm.log_filter.unwrap_or_default() }.into_element(),
        Page::About => pages::about().into_element(),
        Page::ColorPalette => pages::color_palette().into_element(),
    };

    // A 1px frame of `border-strong` around the rounded `.app-shell`.
    rect().expanded().background(p.outside).child(
        rect().expanded().corner_radius(8.).background(p.border_strong).padding(1.).child(
            rect()
                .expanded()
                .corner_radius(7.)
                .overflow(Overflow::Clip)
                .background(p.surface)
                .color(p.body)
                .font_family(SANS)
                .font_size(14.)
                .text_height(TextHeightBehavior::All)
                .child(titlebar(title))
                .child(
                    rect()
                        .width(Size::fill())
                        .height(Size::flex(1.))
                        .content(Content::Flex)
                        .horizontal()
                        .child(components::sidebar(page, device_trust))
                        .child(rect().width(Size::flex(1.)).height(Size::fill()).background(p.canvas).child(content)),
                ),
        ),
    )
}

fn titlebar(title: &'static str) -> impl IntoElement {
    let p = pal();
    rect()
        .width(Size::fill())
        .height(Size::px(56.))
        .padding((0., 12., 0., 16.))
        .horizontal()
        .main_align(Alignment::SpaceBetween)
        .cross_align(Alignment::Center)
        .background(p.surface)
        .border(components::border_bottom(p.border))
        .window_drag()
        .child(text(title, 14.).font_weight(FontWeight::SEMI_BOLD).color(p.heading))
        .child(
            components::icon_button(icon(Icon::Close, 16., p.body), "Close window")
                .on_press(|_| Platform::get().close_window(Platform::window_id())),
        )
}
