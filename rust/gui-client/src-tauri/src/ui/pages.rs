mod about;
mod color_palette;
mod developer_settings;
mod device_trust;
mod diagnostics;
mod general_settings;
mod overview;

pub(crate) use about::About;
pub(crate) use color_palette::color_palette;
pub(crate) use developer_settings::developer_settings;
pub(crate) use device_trust::device_trust;
pub(crate) use diagnostics::Diagnostics;
pub(crate) use general_settings::GeneralSettings;
pub(crate) use overview::Overview;

use freya::prelude::*;

const LOGO: &[u8] = include_bytes!("../../assets/logo.png");

fn logo() -> ImageViewer {
    ImageViewer::new(LOGO)
        .width(Size::px(80.))
        .height(Size::px(80.))
}
