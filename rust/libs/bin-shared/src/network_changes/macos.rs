use crate::DnsControlMethod;
use anyhow::Result;
use futures::{Stream, StreamExt as _, stream};
use std::pin::Pin;

pub async fn new_dns_notifier(
    _tokio_handle: tokio::runtime::Handle,
    _method: DnsControlMethod,
) -> Result<impl Stream<Item = Result<()>> + Unpin> {
    Err::<stream::Pending<_>, _>(anyhow::anyhow!("Not implemented"))
}

pub async fn new_network_notifier() -> Result<impl Stream<Item = Result<()>> + Default + Unpin> {
    Err::<NetworkNotifier, _>(anyhow::anyhow!("Not implemented"))
}

struct NetworkNotifier(futures::stream::BoxStream<'static, Result<()>>);

impl Default for NetworkNotifier {
    fn default() -> Self {
        NetworkNotifier(stream::pending().boxed())
    }
}

impl Stream for NetworkNotifier {
    type Item = Result<()>;

    fn poll_next(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        self.0.as_mut().poll_next(cx)
    }
}
