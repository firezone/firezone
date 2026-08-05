pub(crate) enum Endpoint<T> {
    Active(T),
    Retired,
}

impl<T> Endpoint<T> {
    pub(crate) fn active(&self) -> Option<&T> {
        match self {
            Self::Active(endpoint) => Some(endpoint),
            Self::Retired => None,
        }
    }

    pub(crate) fn active_mut(&mut self) -> Option<&mut T> {
        match self {
            Self::Active(endpoint) => Some(endpoint),
            Self::Retired => None,
        }
    }

    pub(crate) fn is_retired(&self) -> bool {
        matches!(self, Self::Retired)
    }

    pub(crate) fn retire(&mut self) {
        *self = Self::Retired;
    }

    pub(crate) fn activate(&mut self, endpoint: T) {
        *self = Self::Active(endpoint);
    }
}
