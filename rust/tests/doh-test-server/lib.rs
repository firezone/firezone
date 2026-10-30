use std::{convert::Infallible, net::Ipv4Addr, sync::Arc};

use anyhow::Result;
use base64::{Engine as _, prelude::BASE64_URL_SAFE_NO_PAD};
use bytes::Bytes;
use dns_types::{DoHUrl, Query, RecordType, ResponseBuilder, ResponseCode};
use http_body_util::Full;
use hyper::{
    Request, Response, StatusCode, Uri,
    body::Incoming,
    header::{CONTENT_TYPE, HeaderValue},
};
use hyper_util::rt::{TokioExecutor, TokioIo};
use rustls::{RootCertStore, ServerConfig, pki_types::PrivatePkcs8KeyDer};
use tokio::{net::TcpListener, task::JoinSet};
use tokio_rustls::TlsAcceptor;
use tokio_util::task::AbortOnDropHandle;

/// A DoH server on `127.0.0.1` that answers every A query with the same address.
///
/// The server stops when this is dropped.
pub struct DohTestServer {
    url: DoHUrl,
    roots: RootCertStore,
    _task: AbortOnDropHandle<()>,
}

impl DohTestServer {
    /// Starts a server that answers A queries with `answer`.
    pub async fn spawn(answer: Ipv4Addr) -> Result<Self> {
        let certified = rcgen::generate_simple_self_signed(vec!["127.0.0.1".to_owned()])?;
        let certificate = certified.cert.der().clone();
        let key = PrivatePkcs8KeyDer::from(certified.signing_key.serialize_der());
        let mut roots = RootCertStore::empty();
        roots.add(certificate.clone())?;

        let mut tls_config =
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()?
                .with_no_client_auth()
                .with_single_cert(vec![certificate.clone()], key.into())?;
        tls_config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let url = format!("https://{}/dns-query", listener.local_addr()?).parse()?;
        let acceptor = TlsAcceptor::from(Arc::new(tls_config));

        Ok(Self {
            url,
            roots,
            _task: AbortOnDropHandle::new(tokio::spawn(serve(listener, acceptor, answer))),
        })
    }

    pub fn url(&self) -> DoHUrl {
        self.url.clone()
    }

    /// Returns a root store that trusts the server's certificate.
    pub fn root_cert_store(&self) -> RootCertStore {
        self.roots.clone()
    }
}

async fn serve(listener: TcpListener, acceptor: TlsAcceptor, answer: Ipv4Addr) {
    let mut connections = JoinSet::new();

    while let Ok((stream, _)) = listener.accept().await {
        let acceptor = acceptor.clone();

        connections.spawn(async move {
            let Ok(stream) = acceptor.accept(stream).await else {
                return;
            };
            let service = hyper::service::service_fn(move |request| async move {
                Ok::<_, Infallible>(handle(request, answer))
            });

            let _ = hyper_util::server::conn::auto::Builder::new(TokioExecutor::new())
                .serve_connection(TokioIo::new(stream), service)
                .await;
        });
    }
}

fn handle(request: Request<Incoming>, answer: Ipv4Addr) -> Response<Full<Bytes>> {
    let Some(query) = parse_query(request.uri()) else {
        let mut response = Response::new(Full::default());
        *response.status_mut() = StatusCode::BAD_REQUEST;

        return response;
    };

    let record = (query.qtype() == RecordType::A)
        .then(|| (query.domain(), 300, dns_types::records::a(answer)));
    let message = ResponseBuilder::for_query(&query, ResponseCode::NOERROR)
        .with_records(record)
        .build()
        .into_bytes(u16::MAX);

    let mut response = Response::new(Full::new(Bytes::from(message)));
    response.headers_mut().insert(
        CONTENT_TYPE,
        HeaderValue::from_static("application/dns-message"),
    );

    response
}

fn parse_query(uri: &Uri) -> Option<Query> {
    let dns = uri.query()?.strip_prefix("dns=")?;
    let bytes = BASE64_URL_SAFE_NO_PAD.decode(dns).ok()?;

    Query::parse(&bytes).ok()
}
