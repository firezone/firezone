use crate::client::gui::ControllerRequest;

use http_body_util::Full;
use hyper::{
    body::{Bytes, Incoming as IncomingBody},
    service::Service,
    Request, Response,
};
use std::{future::Future, net::SocketAddr, pin::Pin};
use tokio::{net::TcpListener, sync::mpsc};

pub(crate) async fn _local_webserver(
    ctlr_tx: mpsc::Sender<ControllerRequest>,
) -> anyhow::Result<()> {
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0))).await?;
    let local_addr = listener.local_addr()?;
    tracing::info!("Local web server running on {local_addr}");

    loop {
        let (tcp, _) = listener.accept().await?;
        let io = hyper_util::rt::TokioIo::new(tcp);
        let ctlr_tx = ctlr_tx.clone();

        tokio::spawn(async move {
            if let Err(err) = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, WebService { ctlr_tx })
                .await
            {
                tracing::warn!("Error serving HTTP request: {err:?}");
            }
        });
    }
}

struct WebService {
    ctlr_tx: mpsc::Sender<ControllerRequest>,
}

impl Service<Request<IncomingBody>> for WebService {
    type Response = Response<Full<Bytes>>;
    type Error = anyhow::Error;
    type Future = Pin<Box<dyn Future<Output = Result<Self::Response, Self::Error>> + Send>>;

    fn call(&self, _req: Request<IncomingBody>) -> Self::Future {
        let ctlr_tx = self.ctlr_tx.clone();
        Box::pin(async move {
            ctlr_tx.send(ControllerRequest::SignIn).await?;
            Ok(Response::builder()
                .body(Full::new(Bytes::from("bogus")))
                .unwrap())
        })
    }
}
