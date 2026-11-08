use std::time::Duration;

use freya::prelude::*;
use tokio::sync::mpsc;

pub const ROBOTO: &str = "Roboto";
pub const ROBOTO_REGULAR: &[u8] = include_bytes!("../assets/roboto-400.ttf");
pub const ROBOTO_BOLD: &[u8] = include_bytes!("../assets/roboto-700.ttf");

/// What the Controller pushes into the UI.
#[derive(Clone, Debug, PartialEq)]
pub struct ViewModel {
    pub session: String,
    pub auth_url: String,
    pub api_url: String,
    pub log_filter: String,
    pub auth_url_managed: bool,
}

impl Default for ViewModel {
    fn default() -> Self {
        Self {
            session: "Signed out".into(),
            auth_url: "https://app.firezone.dev".into(),
            api_url: "wss://api.firezone.dev".into(),
            log_filter: "info".into(),
            auth_url_managed: true,
        }
    }
}

/// What the UI sends to the Controller.
#[derive(Clone, Debug, PartialEq)]
pub enum Request {
    ApplyAdvanced { auth_url: String, api_url: String, log_filter: String },
    ResetAdvanced,
}

/// Root context shared by every window: the view model and the request sender.
#[derive(Clone)]
pub struct Bridge {
    pub vm: State<ViewModel>,
    pub requests: mpsc::UnboundedSender<Request>,
    pub dark: bool,
}

/// UI side of the glue: apply view-model updates from the Controller to the global state.
pub async fn apply_updates(mut updates: mpsc::UnboundedReceiver<ViewModel>, mut vm: State<ViewModel>) {
    while let Some(new) = updates.recv().await {
        vm.set(new);
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Page {
    Overview,
    General,
    Advanced,
    Diagnostics,
    About,
}

struct Palette {
    bg: Color,
    sidebar: Color,
    card: Color,
    text: Color,
    muted: Color,
    accent: Color,
    accent_bg: Color,
    border: Color,
    warn_bg: Color,
    warn_text: Color,
}

const LIGHT: Palette = Palette {
    bg: Color::from_rgb(241, 243, 247),
    sidebar: Color::WHITE,
    card: Color::WHITE,
    text: Color::from_rgb(17, 24, 39),
    muted: Color::from_rgb(107, 114, 128),
    accent: Color::from_rgb(255, 120, 34),
    accent_bg: Color::from_rgb(255, 243, 235),
    border: Color::from_rgb(229, 231, 235),
    warn_bg: Color::from_rgb(254, 243, 199),
    warn_text: Color::from_rgb(146, 64, 14),
};

const DARK: Palette = Palette {
    bg: Color::from_rgb(17, 24, 39),
    sidebar: Color::from_rgb(31, 41, 55),
    card: Color::from_rgb(31, 41, 55),
    text: Color::from_rgb(243, 244, 246),
    muted: Color::from_rgb(156, 163, 175),
    accent: Color::from_rgb(255, 140, 66),
    accent_bg: Color::from_rgb(55, 45, 40),
    border: Color::from_rgb(55, 65, 81),
    warn_bg: Color::from_rgb(69, 46, 10),
    warn_text: Color::from_rgb(253, 230, 138),
};

pub fn app() -> impl IntoElement {
    let bridge = use_consume::<Bridge>();
    let p = if bridge.dark { &DARK } else { &LIGHT };
    use_init_theme(|| {
        let mut theme = if bridge.dark { dark_theme() } else { light_theme() };
        theme.colors.primary = p.accent;
        theme
    });
    let page = use_state(|| Page::Advanced);

    rect()
        .expanded()
        .horizontal()
        .background(p.bg)
        .color(p.text)
        .font_family(ROBOTO)
        .font_size(14.)
        .child(sidebar(p, page, bridge.vm.read().session.clone()))
        .child(
            rect()
                .expanded()
                .padding(20.)
                .spacing(14.)
                .child(content(p, page(), &bridge)),
        )
}

fn sidebar(p: &Palette, mut page: State<Page>, session: String) -> impl IntoElement {
    let item = |text: &'static str, target: Page, indent: f32| {
        let active = page() == target;
        rect()
            .width(Size::fill())
            .padding((8., 10., 8., 10. + indent))
            .corner_radius(6.)
            .maybe(active, |r| r.background(p.accent_bg).color(p.accent))
            .a11y_role(AccessibilityRole::Link)
            .a11y_alt(text)
            .on_press(move |_| page.set(target))
            .child(label().text(text).font_weight(if active { FontWeight::BOLD } else { FontWeight::NORMAL }))
    };
    rect()
        .width(Size::px(210.))
        .height(Size::fill())
        .background(p.sidebar)
        .padding(10.)
        .main_align(Alignment::SpaceBetween)
        .child(
            rect()
                .width(Size::fill())
                .spacing(2.)
                .child(item("Overview", Page::Overview, 0.))
                .child(rect().padding((8., 10.)).color(p.muted).child("Settings"))
                .child(item("General", Page::General, 14.))
                .child(item("Advanced", Page::Advanced, 14.))
                .child(item("Diagnostics", Page::Diagnostics, 0.))
                .child(item("About", Page::About, 0.)),
        )
        .child(
            paragraph()
                .color(p.muted)
                .font_size(12.)
                .span(Span::new("Session: ").font_weight(FontWeight::BOLD))
                .span(Span::new(session)),
        )
}

fn content(p: &Palette, page: Page, bridge: &Bridge) -> Element {
    match page {
        Page::Advanced => AdvancedSettings { bridge: bridge.clone(), dark: bridge.dark }.into_element(),
        Page::Overview => title(p, "Overview"),
        Page::General => title(p, "General Settings"),
        Page::Diagnostics => title(p, "Diagnostics"),
        Page::About => title(p, "About Firezone"),
    }
}

fn title(_p: &Palette, text: &'static str) -> Element {
    label().text(text).font_size(20.).font_weight(FontWeight::BOLD).into_element()
}

#[derive(Clone)]
struct AdvancedSettings {
    bridge: Bridge,
    dark: bool,
}

impl PartialEq for AdvancedSettings {
    fn eq(&self, other: &Self) -> bool {
        self.bridge.vm == other.bridge.vm && self.dark == other.dark
    }
}

impl Component for AdvancedSettings {
    fn render(&self) -> impl IntoElement {
        let p = if self.dark { &DARK } else { &LIGHT };
        let vm = self.bridge.vm;
        let auth_url = use_state(|| vm.peek().auth_url.clone());
        let mut api_url = use_state(|| vm.peek().api_url.clone());
        let mut log_filter = use_state(|| vm.peek().log_filter.clone());
        let managed = vm.read().auth_url_managed;

        use_side_effect(move || {
            let vm = vm.read();
            api_url.set(vm.api_url.clone());
            log_filter.set(vm.log_filter.clone());
        });

        let tx = self.bridge.requests.clone();
        let apply = move |_| {
            let _ = tx.send(Request::ApplyAdvanced {
                auth_url: auth_url.read().clone(),
                api_url: api_url.read().clone(),
                log_filter: log_filter.read().clone(),
            });
        };
        let tx = self.bridge.requests.clone();
        let reset = move |_| {
            let _ = tx.send(Request::ResetAdvanced);
        };

        let row = |name: &'static str, value: State<String>, locked: bool| {
            let input = Input::new(value).enabled(!locked).width(Size::px(360.));
            let input: Element = if locked {
                TooltipContainer::new(Tooltip::new_text("This setting is managed by your organisation."))
                    .delay(Duration::ZERO)
                    .child(input)
                    .into_element()
            } else {
                input.into_element()
            };
            rect()
                .width(Size::fill())
                .horizontal()
                .cross_align(Alignment::Center)
                .padding((10., 14.))
                .child(
                    rect()
                        .width(Size::px(230.))
                        .child(label().text(if locked { format!("{name} (managed)") } else { name.to_string() }).font_weight(FontWeight::BOLD)),
                )
                .child(input)
        };

        rect()
            .width(Size::fill())
            .spacing(14.)
            .child(label().text("Advanced Settings").font_size(20.).font_weight(FontWeight::BOLD))
            .child(
                rect()
                    .width(Size::fill())
                    .padding(12.)
                    .corner_radius(6.)
                    .background(p.warn_bg)
                    .color(p.warn_text)
                    .child(
                        paragraph()
                            .span(Span::new("WARNING: ").font_weight(FontWeight::BOLD))
                            .span("These settings are intended for internal debug purposes only. Changing them will disrupt access to your Firezone resources."),
                    ),
            )
            .child(
                rect()
                    .width(Size::fill())
                    .background(p.card)
                    .corner_radius(6.)
                    .border(Border::new().fill(p.border).width(1.))
                    .child(row("Auth Base URL", auth_url, managed))
                    .child(row("API URL", api_url, false))
                    .child(row("Log Filter", log_filter, false)),
            )
            .child(
                rect()
                    .width(Size::fill())
                    .horizontal()
                    .main_align(Alignment::End)
                    .spacing(8.)
                    .child(Button::new().on_press(reset).child("Reset to Defaults"))
                    .child(Button::new().filled().on_press(apply).child("Apply")),
            )
    }
}
