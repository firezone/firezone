use iced::{
    Background,
    Border,
    Color,
    executor,
    multi_window::Application,
    Renderer,
    widget::{button, column, container, text},
    window, Alignment, Command, Element, Length, Settings,
};

pub fn main() -> iced::Result {
    FirezoneApp::run(Settings::default())
}

struct FirezoneApp {
    theme: FzTheme,
    value: i32,
}

#[derive(Clone, Default)]
struct FzTheme {}

impl iced::application::StyleSheet for FzTheme {
    type Style = ();

    fn appearance(&self, _style: &Self::Style) -> iced::application::Appearance {
        iced::application::Appearance {
            background_color: Color::from_rgb8(0, 0, 0),
            text_color: Color::from_rgb8(255, 255, 255),
        }
    }
}

impl button::StyleSheet for FzTheme {
    type Style = ();

    fn active(&self, _style: &Self::Style) -> button::Appearance {
        let mut x = button::Appearance::default();
        x.background = Some(Background::Color(Color::from_rgb8(0, 0, 0)));
        x.border = Border {
            color: Color::from_rgb8(255, 255, 255),
            width: 2.0,
            radius: 5.0.into(),
        };
        x.text_color = Color::from_rgb8(255, 255, 255);
        x
    }

    fn hovered(&self, _style: &Self::Style) -> button::Appearance {
        let mut x = button::Appearance::default();
        x.background = Some(Background::Color(Color::from_rgb8(255, 255, 255)));
        x.border = Border {
            color: Color::from_rgba8(0, 0, 0, 0.0),
            width: 2.0,
            radius: 5.0.into(),
        };
        x.text_color = Color::from_rgb8(0, 0, 0);
        x
    }

    fn pressed(&self, _style: &Self::Style) -> button::Appearance {
        let mut x = button::Appearance::default();
        x.background = Some(Background::Color(Color::from_rgb8(0, 0, 0)));
        x.border = Border {
            color: Color::from_rgba8(0, 0, 0, 0.0),
            width: 2.0,
            radius: 5.0.into(),
        };
        x.text_color = Color::from_rgb8(255, 255, 255);
        x
    }

    fn disabled(&self, _style: &Self::Style) -> button::Appearance {
        let mut x = button::Appearance::default();
        x.background = Some(Background::Color(Color::from_rgb8(96, 96, 96)));
        x.border = Border {
            color: Color::from_rgba8(0, 0, 0, 0.0),
            width: 2.0,
            radius: 5.0.into(),
        };
        x.text_color = Color::from_rgb8(0, 0, 0);
        x
    }
}

impl container::StyleSheet for FzTheme {
    type Style = ();

    fn appearance(&self, _style: &Self::Style) -> container::Appearance {
        Default::default()
    }
}

impl text::StyleSheet for FzTheme {
    type Style = ();

    fn appearance(&self, _style: Self::Style) -> text::Appearance {
        Default::default()
    }
}

#[derive(Debug, Clone, Copy)]
enum Message {
    IncrementPressed,
    DecrementPressed,
}

impl Application for FirezoneApp {
    type Executor = executor::Default;
    type Flags = ();
    type Message = Message;
    type Theme = FzTheme;

    fn new(_flags: ()) -> (Self, Command<Message>) {
        (
            Self {
                theme: Default::default(),
                value: 0,
            },
            Command::none(),
        )
    }

    fn theme(&self, window: window::Id) -> Self::Theme {
        self.theme.clone()
    }

    fn title(&self, window: window::Id) -> String {
        match window {
            _ => String::from("Firezone Client"),
        }
    }

    fn update(&mut self, message: Message) -> Command<Message> {
        match message {
            Message::IncrementPressed => {
                self.value += 1;
            }
            Message::DecrementPressed => {
                self.value -= 1;
            }
        }
        Command::none()
    }

    fn view(&self, window: window::Id) -> Element<'_, Message, FzTheme, Renderer> {
        match window {
            _ => self.view_welcome(),
        }
    }
}

impl FirezoneApp {
    fn view_welcome(&self) -> Element<'_, Message, FzTheme, Renderer> {
        let content = column![
            button("Increment").on_press(Message::IncrementPressed),
            text(self.value).size(50),
            button("Decrement").on_press(Message::DecrementPressed)
        ]
        .padding(20)
        .align_items(Alignment::Center);

        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x()
            .center_y()
            .into()
    }
}
