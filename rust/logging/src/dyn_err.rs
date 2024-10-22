use std::error::Error;

pub fn std_dyn_err(e: &(impl Error + 'static)) -> &(dyn Error + 'static) {
    e as &(dyn Error + 'static)
}

pub fn anyhow_dyn_err(e: &anyhow::Error) -> &(dyn Error + 'static) {
    e.as_ref()
}
