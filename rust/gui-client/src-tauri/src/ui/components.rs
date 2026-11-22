//! The building blocks the pages share.

use std::{borrow::Cow, time::Duration};

use freya::prelude::*;

use super::{MONO, Page, theme};

pub(crate) fn pal() -> &'static theme::Palette {
    match *Platform::get().current_window().preferred_theme.read() {
        PreferredTheme::Light => &theme::LIGHT,
        PreferredTheme::Dark => &theme::DARK,
    }
}

/// A label with the line height the design uses for its font size.
pub(crate) fn text(text: impl Into<Cow<'static, str>>, size: f32) -> Label {
    let line = match size as u32 {
        12 => 16.,
        14 => 20.,
        16 => 24.,
        _ => 28.,
    };

    label().text(text).font_size(size).line_height(line / size)
}

pub(crate) fn border(color: Color) -> Border {
    Border::new()
        .fill(color)
        .width(1.)
        .alignment(BorderAlignment::Inner)
}

pub(crate) fn border_bottom(color: Color) -> Border {
    border(color).width(BorderWidth::default().bottom(1.))
}

pub(crate) fn border_top(color: Color) -> Border {
    border(color).width(BorderWidth::default().top(1.))
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Icon {
    Alert,
    ArrowDown,
    Certificate,
    Check,
    Close,
    Code,
    Database,
    DeleteBin,
    Home,
    Information,
    Lock,
    Palette,
    Settings,
    ShareForward,
}

/// A Remix Icon, tinted through its `currentColor`.
pub(crate) fn icon(icon: Icon, size: f32, color: Color) -> SvgViewer {
    let svg: &'static [u8] = match icon {
        Icon::Alert => include_bytes!("../../assets/icons/alert-line.svg"),
        Icon::ArrowDown => include_bytes!("../../assets/icons/arrow-down-s-line.svg"),
        Icon::Certificate => include_bytes!("../../assets/icons/certificate-line.svg"),
        Icon::Check => include_bytes!("../../assets/icons/checkbox-circle-line.svg"),
        Icon::Close => include_bytes!("../../assets/icons/close-line.svg"),
        Icon::Code => include_bytes!("../../assets/icons/code-s-slash-line.svg"),
        Icon::Database => include_bytes!("../../assets/icons/database-2-line.svg"),
        Icon::DeleteBin => include_bytes!("../../assets/icons/delete-bin-line.svg"),
        Icon::Home => include_bytes!("../../assets/icons/home-line.svg"),
        Icon::Information => include_bytes!("../../assets/icons/information-line.svg"),
        Icon::Lock => include_bytes!("../../assets/icons/lock-line.svg"),
        Icon::Palette => include_bytes!("../../assets/icons/palette-line.svg"),
        Icon::Settings => include_bytes!("../../assets/icons/settings-3-line.svg"),
        Icon::ShareForward => include_bytes!("../../assets/icons/share-forward-line.svg"),
    };

    SvgViewer::new(svg)
        .width(Size::px(size))
        .height(Size::px(size))
        .color(color)
        .show_loader(false)
}

pub(crate) fn icon_button(child: impl IntoElement, name: &'static str) -> Rect {
    rect()
        .width(Size::px(32.))
        .height(Size::px(32.))
        .center()
        .corner_radius(4.)
        .a11y_role(AccessibilityRole::Button)
        .a11y_alt(name)
        .child(child)
}

#[derive(Clone, Copy)]
pub(crate) enum Variant {
    Primary,
    Secondary,
    Danger,
}

pub(crate) fn button(label: &'static str, variant: Variant) -> Rect {
    let p = pal();
    let (background, outline, color) = match variant {
        Variant::Primary => (p.brand, p.brand, Color::WHITE),
        Variant::Secondary => (p.surface, p.border_strong, p.body),
        Variant::Danger => (p.surface, p.danger.with_a(102), p.danger),
    };

    rect()
        .padding((9., 13.))
        .corner_radius(4.)
        .background(background)
        .border(border(outline))
        .color(color)
        .a11y_role(AccessibilityRole::Button)
        .a11y_alt(label)
        .child(text(label, 14.).font_weight(FontWeight::MEDIUM))
}

/// A panel whose rows are divided by lines.
pub(crate) fn card(rows: impl IntoIterator<Item = Element>) -> Rect {
    let p = pal();

    rect()
        .width(Size::fill())
        .padding(1.)
        .corner_radius(4.)
        .background(p.surface)
        .border(border(p.border))
        .children(divided(rows))
}

pub(crate) fn divided(rows: impl IntoIterator<Item = Element>) -> impl Iterator<Item = Element> {
    let p = pal();

    rows.into_iter().enumerate().flat_map(move |(i, row)| {
        let divider = (i > 0).then(|| {
            rect()
                .width(Size::fill())
                .height(Size::px(1.))
                .background(p.border)
                .into_element()
        });

        divider.into_iter().chain([row])
    })
}

/// A titled card, and the notes under it.
pub(crate) fn section(
    title: &'static str,
    card: Rect,
    notes: impl IntoIterator<Item = Element>,
) -> Rect {
    let p = pal();

    rect()
        .width(Size::fill())
        .child(
            text(title, 12.)
                .font_weight(FontWeight::SEMI_BOLD)
                .color(p.body)
                .margin((0., 0., 6., 0.)),
        )
        .child(card)
        .children(notes)
}

pub(crate) fn note(with: Icon, message: &'static str) -> Element {
    let p = pal();

    rect()
        .horizontal()
        .spacing(6.)
        .padding((6., 8., 0., 8.))
        .color(p.subtle)
        .child(icon(with, 14., p.subtle).margin((1., 0., 0., 0.)))
        .child(text(message, 12.))
        .into()
}

pub(crate) fn managed_notice() -> Element {
    note(
        Icon::Lock,
        "Some settings are managed by your organization.",
    )
}

/// A labelled row with a control on its right, and what is wrong with the control's value.
///
/// A `field` control takes the width of a text field.
pub(crate) fn setting_row(
    label: &'static str,
    managed: bool,
    field: bool,
    control: impl IntoElement,
    error: Option<String>,
) -> Element {
    let p = pal();
    let title = rect()
        .horizontal()
        .cross_align(Alignment::Center)
        .spacing(6.)
        .child(
            text(label, 14.)
                .font_weight(FontWeight::MEDIUM)
                .color(p.heading),
        )
        .maybe_child(managed.then(|| icon(Icon::Lock, 14., p.subtle)));
    let control: Element = if field {
        rect()
            .width(Size::px(256.))
            .height(Size::px(36.))
            .horizontal()
            .main_align(Alignment::End)
            .cross_align(Alignment::Center)
            .child(control)
            .into()
    } else {
        control.into_element()
    };

    rect()
        .width(Size::fill())
        .padding((8., 8., 8., 16.))
        .child(
            rect()
                .width(Size::fill())
                .horizontal()
                .main_align(Alignment::SpaceBetween)
                .cross_align(Alignment::Center)
                .child(title)
                .child(control),
        )
        .maybe_child(error.map(|error| {
            rect()
                .width(Size::fill())
                .cross_align(Alignment::End)
                .child(
                    rect()
                        .width(Size::px(256.))
                        .padding((4., 0., 4., 0.))
                        .child(text(error, 12.).color(p.error)),
                )
        }))
        .into()
}

/// A labelled row with a switch, sized like the rows with a text field.
pub(crate) fn toggle(
    label: &'static str,
    checked: bool,
    managed: bool,
    on_change: impl FnMut(bool) + 'static,
) -> Element {
    setting_row(
        label,
        managed,
        true,
        switch(label, checked, managed, on_change),
        None,
    )
}

pub(crate) fn switch(
    label: &'static str,
    checked: bool,
    managed: bool,
    mut on_change: impl FnMut(bool) + 'static,
) -> Rect {
    let p = pal();
    let thumb = rect()
        .width(Size::px(16.))
        .height(Size::px(16.))
        .corner_radius(8.)
        .background(Color::WHITE)
        .shadow((0., 1., 3., 0., Color::from_argb(26, 0, 0, 0)))
        .shadow((0., 1., 2., -1., Color::from_argb(26, 0, 0, 0)))
        .margin((0., 0., 0., if checked { 14. } else { 0. }));
    rect()
        .width(Size::px(36.))
        .height(Size::px(20.))
        .padding((0., 3.))
        .main_align(Alignment::Center)
        .corner_radius(10.)
        .background(if checked { p.brand } else { p.raised })
        .border(border(if checked { p.brand } else { p.border_emphasis }))
        .a11y_role(AccessibilityRole::Switch)
        .a11y_alt(label)
        .a11y_enabled(!managed)
        .a11y_builder(move |node| node.set_toggled(accesskit::Toggled::from(checked)))
        .maybe(managed, |r| r.opacity(0.4))
        .maybe(!managed, |r| r.on_press(move |_| on_change(!checked)))
        .child(thumb)
}

/// A closed box that opens the list of its options under itself.
///
/// Freya's `Select` fixes its padding, radius and arrow.
#[derive(PartialEq)]
pub(crate) struct Select {
    pub(crate) options: &'static [&'static str],
    pub(crate) selected: usize,
    pub(crate) managed: bool,
    pub(crate) on_change: EventHandler<usize>,
}

impl Component for Select {
    fn render(&self) -> impl IntoElement {
        let p = pal();
        let mut open = use_state(|| false);
        let on_change = self.on_change.clone();
        let item = |(i, option): (usize, &&'static str)| {
            let on_change = on_change.clone();

            rect()
                .width(Size::fill())
                .padding((6., 8.))
                .corner_radius(3.)
                .a11y_role(AccessibilityRole::ListBoxOption)
                .a11y_alt(*option)
                .on_press(move |_| {
                    open.set(false);
                    on_change.call(i);
                })
                .child(text(*option, 14.).color(p.heading))
                .into_element()
        };

        rect()
            .width(Size::fill())
            .child(
                rect()
                    .width(Size::fill())
                    .height(Size::px(36.))
                    .padding((0., 12.))
                    .horizontal()
                    .content(Content::Flex)
                    .cross_align(Alignment::Center)
                    .corner_radius(4.)
                    .background(p.control_bg)
                    .border(border(p.control_border))
                    .a11y_role(AccessibilityRole::ComboBox)
                    .a11y_alt(self.options[self.selected])
                    .maybe(self.managed, |r| r.opacity(0.4))
                    .maybe(!self.managed, |r| {
                        r.on_press(move |e: Event<PressEventData>| {
                            e.prevent_default();
                            e.stop_propagation();
                            open.toggle();
                        })
                        .on_global_pointer_up(move |_| open.set_if_modified(false))
                    })
                    .child(
                        text(self.options[self.selected], 14.)
                            .color(p.heading)
                            .width(Size::flex(1.)),
                    )
                    .child(icon(Icon::ArrowDown, 16., p.subtle)),
            )
            .maybe_child(open().then(|| {
                rect().width(Size::fill()).height(Size::px(0.)).child(
                    rect()
                        .layer(Layer::Overlay)
                        .width(Size::fill())
                        .margin((4., 0., 0., 0.))
                        .padding(4.)
                        .corner_radius(4.)
                        .background(p.overlay)
                        .border(border(p.border_strong))
                        .shadow((0., 4., 12., 0., Color::from_argb(40, 0, 0, 0)))
                        .children(self.options.iter().enumerate().map(item)),
                )
            }))
    }
}

pub(crate) fn is_url(value: &str, schemes: &[&str]) -> bool {
    url::Url::parse(value).is_ok_and(|url| {
        url.host_str().is_some_and(|h| !h.is_empty()) && schemes.contains(&url.scheme())
    })
}

/// A text field that saves on Enter and when it loses focus, and reverts on Escape.
#[derive(PartialEq)]
pub(crate) struct TextSetting {
    pub(crate) label: &'static str,
    pub(crate) value: String,
    /// What the field shows, owned by the page so that it can see drafts.
    pub(crate) text: State<String>,
    pub(crate) managed: bool,
    pub(crate) mono: bool,
    /// The URL schemes the value may have, and what to say when it has none of them.
    pub(crate) validate: Option<(&'static [&'static str], &'static str)>,
    /// Saves the value, returning why it was rejected.
    pub(crate) save: Callback<String, Option<String>>,
}

impl Component for TextSetting {
    fn render(&self) -> impl IntoElement {
        let p = pal();
        let mut text = self.text;
        // The draft a problem was found with: it shows until the field changes.
        let mut error = use_state(|| None::<(String, String)>);
        let mut last_saved = use_state(|| None::<String>);
        let mut saved = use_state(|| false);
        let value = use_reactive(&self.value);

        use_side_effect(move || {
            text.set(value.read().clone());
            error.set(None);
            if last_saved.write().take().is_some() {
                saved.set(true);
                spawn(async move {
                    timer(Duration::from_secs(2)).await;
                    saved.set(false);
                });
            }
        });

        let (validate, save) = (self.validate, self.save.clone());
        let commit = move |draft: String| {
            if draft == *value.peek() || Some(&draft) == last_saved.peek().as_ref() {
                return;
            }
            if let Some((_, problem)) = validate.filter(|(schemes, _)| !is_url(&draft, schemes)) {
                error.set(Some((draft, problem.to_owned())));
                return;
            }

            last_saved.set(Some(draft.clone()));
            if let Some(rejection) = save.call(draft.clone()) {
                last_saved.set(None);
                error.set(Some((draft, rejection)));
            }
        };

        // Freya's `Input` has no blur event, so a focus change that leaves the field saves it.
        let a11y_id = use_hook(AccessibilityId::new_unique);
        let focus = use_focus(a11y_id);
        let mut was_focused = use_state(|| false);
        let mut commit_on_blur = commit.clone();
        use_side_effect(move || {
            let focused = focus() != Focus::Not;
            if *was_focused.peek() && !focused {
                commit_on_blur(text.peek().clone());
            }
            was_focused.set_if_modified(focused);
        });

        #[expect(
            clippy::wildcard_enum_match_arm,
            reason = "Every other key edits the text"
        )]
        let on_pre_key_down = move |e: Event<KeyboardEventData>| match &e.key {
            Key::Named(NamedKey::Escape) => {
                text.set(value.peek().clone());
                error.set(None);
                true
            }
            Key::Named(NamedKey::Enter | NamedKey::Shift) => true,
            Key::Named(NamedKey::Tab) => false,
            _ => {
                e.stop_propagation();
                e.prevent_default();
                true
            }
        };

        let current = text.read().clone();
        let problem = error
            .read()
            .as_ref()
            .filter(|(draft, _)| *draft == current)
            .map(|(_, problem)| problem.clone());
        let is_draft = current != *value.read();
        let marker: Element = if is_draft {
            rect()
                .width(Size::px(8.))
                .height(Size::px(8.))
                .corner_radius(4.)
                .background(p.brand)
                .into()
        } else if saved() {
            icon(Icon::Check, 16., p.success).into()
        } else {
            rect().into()
        };
        let input = Input::new(text)
            .a11y_id(a11y_id)
            .width(Size::fill())
            .height(Size::px(36.))
            .enabled(!self.managed)
            .on_submit(commit)
            .on_pre_key_down(on_pre_key_down)
            .theme_layout(
                InputLayoutThemePartial::new()
                    .corner_radius(4.)
                    .padding((8., 0., 8., 12.)),
            )
            .theme_colors(
                InputColorsThemePartial::new()
                    .background(if self.managed {
                        Color::TRANSPARENT
                    } else {
                        p.control_bg
                    })
                    .focus_background(p.control_bg)
                    .border_fill(if problem.is_some() {
                        p.error
                    } else {
                        p.control_border
                    })
                    .focus_border_fill(if problem.is_some() { p.error } else { p.focus })
                    .color(p.heading)
                    .placeholder_color(p.muted),
            )
            .trailing(
                rect()
                    .width(Size::px(16.))
                    .height(Size::px(16.))
                    .margin((0., 12., 0., 8.))
                    .center()
                    .child(marker),
            );
        // Freya's `Input` names itself by its value, so the group around it carries the label.
        // It also stays focused when a press elsewhere is handled, so the group unfocuses it.
        let mut area = use_state(Area::default);
        let input = rect()
            .width(Size::fill())
            .a11y_role(AccessibilityRole::Group)
            .a11y_alt(self.label)
            .on_sized(move |e: Event<SizedEventData>| area.set_if_modified(e.area))
            .on_capture_global_pointer_up(move |e: Event<PointerEventData>| {
                if a11y_id.is_focused() && !area.read().contains(e.global_location().to_f32()) {
                    a11y_id.request_unfocus();
                }
            })
            .maybe(self.mono, |r| r.font_family(MONO).font_size(12.))
            .maybe(self.managed, |r| r.opacity(0.4))
            .child(input);

        setting_row(self.label, self.managed, true, input, problem)
    }
}

/// A modal question over a dimmed window, which Escape cancels.
pub(crate) fn confirmation_dialog(
    question: &'static str,
    confirm_label: &'static str,
    on_cancel: impl FnMut() + Clone + 'static,
    mut on_confirm: impl FnMut() + 'static,
) -> Rect {
    let p = pal();
    let shadow =
        |y, blur, spread| Shadow::from((0., y, blur, spread, Color::from_argb(26, 0, 0, 0)));
    let mut cancel = on_cancel.clone();
    let mut escape = on_cancel;

    rect()
        .position(Position::new_global())
        .layer(Layer::Overlay)
        .width(Size::window_percent(100.))
        .height(Size::window_percent(100.))
        .background(Color::from_argb(102, 0, 0, 0))
        .center()
        .on_global_key_down(move |e: Event<KeyboardEventData>| {
            if e.key == Key::Named(NamedKey::Escape) {
                escape();
            }
        })
        .child(
            rect()
                .width(Size::px(384.))
                .padding(20.)
                .corner_radius(8.)
                .background(p.overlay)
                .border(border(p.border_strong))
                .shadow(shadow(20., 25., -5.))
                .shadow(shadow(8., 10., -6.))
                .color(p.heading)
                .a11y_role(AccessibilityRole::Dialog)
                .a11y_alt(question)
                .child(text(question, 16.).font_weight(FontWeight::SEMI_BOLD))
                .child(
                    rect()
                        .width(Size::fill())
                        .margin((20., 0., 0., 0.))
                        .horizontal()
                        .main_align(Alignment::End)
                        .spacing(8.)
                        .child(button("Cancel", Variant::Secondary).on_press(move |_| cancel()))
                        .child(
                            button(confirm_label, Variant::Danger).on_press(move |_| on_confirm()),
                        ),
                ),
        )
}

pub(crate) fn sidebar(
    mut page: State<Page>,
    current: Page,
    device_trust: bool,
    developer: bool,
) -> impl IntoElement {
    let p = pal();
    let item = |with: Icon, label: &'static str, target: Page| {
        let active = current == target;
        let color = if active { p.brand } else { p.body };

        rect()
            .width(Size::fill())
            .horizontal()
            .cross_align(Alignment::Center)
            .spacing(10.)
            .padding((6., 8.))
            .corner_radius(4.)
            .color(color)
            .maybe(active, |r| r.background(p.brand_muted))
            .a11y_role(AccessibilityRole::Link)
            .a11y_alt(label)
            .on_press(move |_| page.set(target))
            .child(icon(with, 16., color))
            .child(text(label, 14.).font_weight(if active {
                FontWeight::MEDIUM
            } else {
                FontWeight::NORMAL
            }))
    };

    rect()
        .width(Size::px(224.))
        .height(Size::fill())
        .padding((12., 9., 12., 8.))
        .spacing(2.)
        .background(p.surface)
        .border(border(p.border).width(BorderWidth::default().right(1.)))
        .child(item(Icon::Home, "Overview", Page::Overview))
        .child(item(Icon::Settings, "Settings", Page::Settings))
        .maybe_child(
            device_trust.then(|| item(Icon::Certificate, "Device Trust", Page::DeviceTrust)),
        )
        .child(item(Icon::Database, "Diagnostics", Page::Diagnostics))
        .child(item(Icon::Information, "About", Page::About))
        .maybe_child(developer.then(|| item(Icon::Code, "Developer", Page::Developer)))
        .maybe_child(cfg!(debug_assertions).then(|| {
            rect()
                .width(Size::fill())
                .margin((10., 0., 0., 0.))
                .padding((13., 0., 0., 0.))
                .border(border_top(p.border))
                .child(item(Icon::Palette, "Color Palette", Page::ColorPalette))
        }))
}

/// A page that scrolls, with a classic scrollbar taking 15px when it overflows.
#[derive(PartialEq)]
pub(crate) struct ScrollPage(pub(crate) Element);

impl Component for ScrollPage {
    fn render(&self) -> impl IntoElement {
        let (mut viewport, mut content) = (use_state(|| 0.), use_state(|| 0.));

        // The `ScrollView`'s own size event reports its viewport, so the content measures itself.
        ScrollView::new()
            .width(Size::fill())
            .height(Size::fill())
            .auto_hide_scrollbars(false)
            .scrollbar(scrollbar)
            .on_sized(move |e: Event<SizedEventData>| viewport.set_if_modified(e.area.height()))
            .child(
                rect()
                    .width(Size::fill())
                    .padding((
                        20.,
                        if content() > viewport() { 35. } else { 20. },
                        20.,
                        20.,
                    ))
                    .on_sized(move |e: Event<SizedEventData>| {
                        content.set_if_modified(e.area.height())
                    })
                    .child(self.0.clone()),
            )
    }
}

fn scrollbar(context: ScrollBarContext) -> Element {
    const ARROW: f32 = 15.;

    let p = pal();
    if context.axis == Axis::X {
        return rect().into();
    }

    let (viewport, content) = (context.viewport_size.height, context.content_size.height);
    let track = viewport - 2. * ARROW;
    let thumb = (track * viewport / content).max(20.);
    let progress = (-context.scroll_position.y / (content - viewport)).clamp(0., 1.);
    let arrow = |path: &str| {
        let svg = format!(
            r#"<svg viewBox="0 0 15 15" xmlns="http://www.w3.org/2000/svg"><path d="{path}" fill="currentColor"/></svg>"#
        );

        SvgViewer::new(Bytes::from(svg))
            .width(Size::px(ARROW))
            .height(Size::px(ARROW))
            .color(p.scroll_thumb)
            .show_loader(false)
    };

    rect()
        .position(Position::new_absolute())
        .offset_x(-ARROW)
        .width(Size::px(ARROW))
        .height(Size::px(viewport))
        .layer(999)
        .background(p.scroll_track)
        .child(arrow("M4 9.5h7L7.5 5.5z"))
        .child(
            rect()
                .width(Size::fill())
                .height(Size::px(track))
                .padding(((track - thumb) * progress, 0., 0., 0.))
                .child(
                    rect()
                        .width(Size::px(9.))
                        .height(Size::px(thumb))
                        .margin((0., 3.))
                        .corner_radius(4.5)
                        .background(p.scroll_thumb),
                ),
        )
        .child(arrow("M4 5.5h7L7.5 9.5z"))
        .into()
}
