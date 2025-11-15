use anyhow::Result;
use dns_types::DoHUrl;
use http_client::HttpClient;

pub async fn send(
    client: HttpClient,
    server: DoHUrl,
    query: dns_types::Query,
) -> Result<dns_types::Response> {
    tracing::trace!(target: "wire::dns::recursive::https", %server, domain = %query.domain());

    let request = query.try_into_http_request(&server)?;
    let response = client.send_request(request)?.await?;
    let response = dns_types::Response::try_from_http_response(response)?;

    Ok(response)
}
