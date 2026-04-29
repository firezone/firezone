use crate::DnsControlMethod;
use anyhow::Result;
use futures::{Stream, stream};

pub async fn new_dns_notifier(
    _tokio_handle: tokio::runtime::Handle,
    _method: DnsControlMethod,
) -> Result<impl Stream<Item = Result<()>> + Unpin> {
    Err::<stream::Pending<_>, _>(anyhow::anyhow!("Not implemented"))
}

pub async fn new_network_notifier() -> Result<impl Stream<Item = Result<()>> + Default + Unpin> {
    Err::<stream::Pending<_>, _>(anyhow::anyhow!("Not implemented"))
}
