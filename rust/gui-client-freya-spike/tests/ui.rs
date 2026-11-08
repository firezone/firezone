use std::{collections::HashMap, error::Error, path::PathBuf, time::Duration};

use freya::prelude::*;
use freya_testing::prelude::*;
use gui_client_freya_spike::*;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

const SIZE: (f32, f32) = (900., 500.);
const AUTH_INPUT: (f64, f64) = (600., 153.);
const API_INPUT: (f64, f64) = (600., 205.);
const LOG_INPUT: (f64, f64) = (600., 257.);
const APPLY: (f64, f64) = (850., 311.);
const RESET: (f64, f64) = (748., 311.);

fn runner(dark: bool) -> (TestingRunner, State<ViewModel>, mpsc::UnboundedReceiver<Request>) {
    let (tx, rx) = mpsc::unbounded_channel();
    let (mut t, vm) = TestingRunner::new(
        app,
        SIZE.into(),
        |r| {
            let vm = State::create_global(ViewModel::default());
            r.provide_root_context(|| Bridge { vm, requests: tx, dark });
            vm
        },
        1.,
    );
    register_roboto(&mut t, ROBOTO);
    t.set_default_fonts(&[ROBOTO.into()]);
    t.run_in(|| GlobalContexts::get().insert_context(Clipboard::create(Some(Box::new(MemoryClipboard::default())))));
    t.sync_and_update();
    (t, vm, rx)
}

fn register_roboto(t: &mut TestingRunner, family: &str) {
    // One file per call: `set_fonts` takes a map keyed by family name.
    t.set_fonts(HashMap::from([(family, ROBOTO_REGULAR)]));
    t.set_fonts(HashMap::from([(family, ROBOTO_BOLD)]));
}

fn screenshot(t: &mut TestingRunner, name: &str) -> String {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("screenshots");
    std::fs::create_dir_all(&dir).unwrap();
    let png = t.render();
    std::fs::write(dir.join(format!("{name}.png")), png.as_bytes()).unwrap();
    let hash = format!("{:x}", Sha256::digest(png.as_bytes()));
    println!("{name}.png sha256={hash}");
    hash
}

fn texts(t: &TestingRunner) -> Vec<String> {
    t.find_many(|_, el| {
        Label::try_downcast(el)
            .map(|l| l.text.to_string())
            .or_else(|| Paragraph::try_downcast(el).map(|p| p.spans.iter().map(|s| s.text.as_ref()).collect()))
    })
}

fn settle(t: &mut TestingRunner) {
    t.poll(Duration::from_millis(10), Duration::from_millis(300));
}

#[test]
fn light_and_dark() {
    let (mut t, _, _) = runner(false);
    screenshot(&mut t, "advanced-light");
    let (mut t, _, _) = runner(true);
    screenshot(&mut t, "advanced-dark");
}

#[test]
fn managed_tooltip_on_hover() {
    let (mut t, _, _) = runner(false);
    t.move_cursor(AUTH_INPUT);
    settle(&mut t);
    assert!(texts(&t).iter().any(|s| s.contains("managed by your organisation")));
    screenshot(&mut t, "advanced-tooltip-light");
}

#[test]
fn sidebar_navigation() {
    let (mut t, _, _) = runner(false);
    t.click_cursor((60., 166.));
    settle(&mut t);
    assert!(texts(&t).contains(&"Diagnostics".to_string()));
    assert!(!texts(&t).contains(&"Advanced Settings".to_string()));
    screenshot(&mut t, "sidebar-diagnostics-light");
}

#[test]
fn typing_and_clipboard() {
    let (mut t, _, mut requests) = runner(false);

    // Type into the API URL: select all, replace.
    click(&mut t, API_INPUT);
    press_ctrl(&mut t, "a");
    t.write_text("wss://staging.example");
    settle(&mut t);
    screenshot(&mut t, "advanced-typed-light");

    // Mouse-select the log filter, copy it, paste it over the API URL.
    t.press_key(Key::Named(NamedKey::Escape));
    t.move_cursor((482., LOG_INPUT.1));
    t.press_cursor((482., LOG_INPUT.1));
    settle(&mut t);
    t.move_cursor((560., LOG_INPUT.1));
    t.release_cursor((560., LOG_INPUT.1));
    press_ctrl(&mut t, "c");
    t.press_key(Key::Named(NamedKey::Escape));
    click(&mut t, API_INPUT);
    press_ctrl(&mut t, "a");
    press_ctrl(&mut t, "v");
    t.press_key(Key::Named(NamedKey::Escape));

    // The locked input ignores clicks and typing. (Clicking outside did not blur the
    // previously focused input in the runner, so blur with Escape above.)
    click(&mut t, AUTH_INPUT);
    t.write_text("evil");

    click(&mut t, APPLY);
    let req = requests.try_recv().expect("Apply sends a request");
    assert_eq!(
        req,
        Request::ApplyAdvanced {
            auth_url: "https://app.firezone.dev".into(),
            api_url: "info".into(),
            log_filter: "info".into(),
        }
    );
}

#[test]
fn controller_roundtrip() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (mut t, vm, mut requests) = runner(false);
    let (vm_tx, vm_rx) = mpsc::unbounded_channel();

    // Controller: a tokio task outside the UI thread.
    rt.spawn(async move {
        let mut model = ViewModel::default();
        model.session = "alice@example.com".into();
        vm_tx.send(model.clone()).unwrap();
        while let Some(req) = requests.recv().await {
            if req == Request::ResetAdvanced {
                model.session = "alice@example.com (reset)".into();
                model.log_filter = "debug".into();
                vm_tx.send(model.clone()).unwrap();
            }
        }
    });
    t.run_in(|| spawn(apply_updates(vm_rx, vm)));

    wait_for(&mut t, |t| texts(t).iter().any(|s| s == "Session: alice@example.com"));
    t.click_cursor(RESET);
    wait_for(&mut t, |t| texts(t).iter().any(|s| s.ends_with("(reset)")));
    assert_eq!(vm.peek().log_filter, "debug");
    assert!(texts(&t).contains(&"debug".to_string()), "input shows the pushed value");
    screenshot(&mut t, "controller-update-light");
}

#[test]
fn font_weights_and_span_family() {
    fn fonts() -> impl IntoElement {
        rect()
            .font_size(20.)
            .child(label().font_family(ROBOTO).text("Firezone Settings"))
            .child(label().font_family(ROBOTO).font_weight(FontWeight::BOLD).text("Firezone Settings"))
            .child(paragraph().font_family(ROBOTO).span(Span::new("Firezone Settings").font_family("BoldOnly")))
    }
    let (mut t, ()) = TestingRunner::new(fonts, SIZE.into(), |_| {}, 1.);
    register_roboto(&mut t, ROBOTO);
    t.set_fonts(HashMap::from([("BoldOnly", ROBOTO_BOLD)]));
    t.sync_and_update();
    let widths: Vec<f32> = t.find_many(|n, el| {
        (Label::try_downcast(el).is_some() || Paragraph::try_downcast(el).is_some()).then(|| n.layout().area.width())
    });
    println!("widths regular/bold/span={widths:?}");
    // Real bold glyphs have wider advances than regular ones (synthetic bold keeps advances).
    assert!(widths[1] > widths[0] + 1.);
    // The span picks its own family over the paragraph's.
    assert!((widths[2] - widths[1]).abs() < 0.5);
}

#[test]
fn accessibility_tree() {
    // The runner only hands out a11y diffs, so mount the app after construction to get it all in one update.
    #[derive(PartialEq)]
    struct Main;
    impl Component for Main {
        fn render(&self) -> impl IntoElement {
            app()
        }
    }
    fn gated() -> impl IntoElement {
        let show = use_consume::<State<bool>>();
        rect().expanded().maybe_child(show().then_some(Main))
    }
    let (tx, _rx) = mpsc::unbounded_channel();
    let (mut t, mut show) = TestingRunner::new(
        gated,
        SIZE.into(),
        |r| {
            let vm = State::create_global(ViewModel::default());
            r.provide_root_context(|| Bridge { vm, requests: tx, dark: false });
            r.provide_root_context(|| State::create(false))
        },
        1.,
    );
    show.set(true);
    let update = t.sync_and_update();
    let nodes: Vec<String> = update
        .nodes
        .iter()
        .filter(|(_, n)| n.role() != accesskit::Role::GenericContainer || n.label().is_some())
        .map(|(_, n)| format!("{:?} {:?}", n.role(), n.label().unwrap_or_default()))
        .collect();
    println!("a11y nodes: {}", update.nodes.len());
    for n in &nodes {
        println!("  {n}");
    }
    assert!(nodes.contains(&r#"Button """#.to_string()) || nodes.iter().any(|n| n.starts_with("Button")));
    assert!(nodes.contains(&r#"TextInput "wss://api.firezone.dev""#.to_string()));
    assert!(nodes.contains(&r#"Link "Diagnostics""#.to_string()));
}

/// Real mice move before they click; inputs track hover state from it.
fn click(t: &mut TestingRunner, at: (f64, f64)) {
    t.move_cursor(at);
    t.click_cursor(at);
}

fn press_ctrl(t: &mut TestingRunner, key: &str) {
    t.send_event(PlatformEvent::Keyboard {
        name: KeyboardEventName::KeyDown,
        key: Key::Character(key.into()),
        code: Code::Unidentified,
        modifiers: Modifiers::CONTROL,
    });
    t.sync_and_update();
}

fn wait_for(t: &mut TestingRunner, cond: impl Fn(&TestingRunner) -> bool) {
    for _ in 0..200 {
        t.handle_events_immediately();
        t.sync_and_update();
        if cond(t) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("condition not met; texts: {:?}", texts(t));
}

#[derive(Default)]
struct MemoryClipboard(String);

impl copypasta::ClipboardProvider for MemoryClipboard {
    fn get_contents(&mut self) -> Result<String, Box<dyn Error + Send + Sync>> {
        Ok(self.0.clone())
    }
    fn set_contents(&mut self, c: String) -> Result<(), Box<dyn Error + Send + Sync>> {
        self.0 = c;
        Ok(())
    }
}
