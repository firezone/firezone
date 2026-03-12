use std::collections::HashMap;

use str0m::ice::TransId;

pub struct InflightStunRequests<TId> {
    inner: HashMap<String, TId>,
}

impl<TId> Default for InflightStunRequests<TId> {
    fn default() -> Self {
        Self {
            inner: HashMap::default(),
        }
    }
}

impl<TId> InflightStunRequests<TId>
where
    TId: PartialEq,
{
    pub fn add(&mut self, conn_id: TId, id: TransId) {
        self.inner.insert(format!("{id:?}"), conn_id); // TODO: Use debug formatting while we wait for https://github.com/algesten/str0m/pull/905
    }

    pub fn remove(&mut self, id: TransId) -> Option<TId> {
        self.inner.remove(&format!("{id:?}"))
    }

    pub fn remove_by_conn_id(&mut self, id: TId) {
        self.inner.retain(|_, c| c != &id);
    }
}
