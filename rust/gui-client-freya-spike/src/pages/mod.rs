mod about;
mod color_palette;
mod device_trust;
mod diagnostics;
mod general_settings;
mod overview;

pub use about::about;
pub use color_palette::color_palette;
pub use device_trust::device_trust;
pub use diagnostics::Diagnostics;
pub use general_settings::GeneralSettingsPage;
pub use overview::Overview;

use freya::prelude::*;

const LOGO: &[u8] = include_bytes!("../../assets/logo.png");

fn logo() -> ImageViewer {
    ImageViewer::new(LOGO)
        .width(Size::px(80.))
        .height(Size::px(80.))
}
