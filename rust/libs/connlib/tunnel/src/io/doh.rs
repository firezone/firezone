use anyhow::Result;
use dns_types::DoHUrl;
use http_client::HttpClient;

pub async fn send(
    client: HttpClient,
    server: DoHUrl,
    query: dns_types::Query,
) -> Result<dns_types::Response> {
    let domain = query.domain();
    let qtype = query.qtype();

    tracing::trace!(target: "wire::dns::recursive::qry", %server, "{qtype} {domain}");

    let request = query.try_into_http_request(&server)?;
    let response = client.send_request(request)?.await?;
    let response = dns_types::Response::try_from_http_response(response)?;

    tracing::trace!(target: "wire::dns::recursive::res", %server, "{qtype} {domain} => {}", response.response_code());

    Ok(response)
}
