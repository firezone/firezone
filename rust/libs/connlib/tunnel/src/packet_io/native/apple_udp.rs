use super::{CompletionPort, LocalQueue, Payload, TrackedOperation};
use anyhow::Result;
use socket_factory::{PerfUdpSocket, SocketFactory};
use std::{net::SocketAddr, sync::Arc};

pub(super) struct UdpSocket(PerfUdpSocket);

impl UdpSocket {
    pub(super) fn bind(
        factory: &Arc<dyn SocketFactory<socket_factory::UdpSocket>>,
        address: SocketAddr,
    ) -> Result<Self> {
        let mut socket = factory.bind(address)?.into_perf()?;
        let buffer_size = |name, fallback| {
            std::env::var(name)
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(fallback)
        };
        socket.set_buffer_sizes(
            buffer_size(
                "FIREZONE_UDP_SEND_BUFFER_SIZE",
                socket_factory::SEND_BUFFER_SIZE,
            ),
            buffer_size(
                "FIREZONE_UDP_RECV_BUFFER_SIZE",
                socket_factory::RECV_BUFFER_SIZE,
            ),
        );
        Ok(Self(socket))
    }

    pub(super) async fn receive(&self, port: &CompletionPort) -> Result<()> {
        let generation = port.generation();
        loop {
            std::future::poll_fn(|cx| port.poll_receive_ready(cx, true)).await;
            port.receive_network_batch(generation, self.0.recv_from().await?)?;
            tokio::task::yield_now().await;
        }
    }

    pub(super) async fn send(
        &self,
        _port: &CompletionPort,
        queue: &LocalQueue<TrackedOperation>,
    ) -> Result<()> {
        loop {
            let TrackedOperation { operation, guard } = queue.pop().await;
            let Payload::Network(datagram) = operation.payload else {
                unreachable!()
            };
            guard.complete(self.0.send(datagram).await)?;
        }
    }

    pub(super) fn close(self) -> std::future::Ready<Result<()>> {
        drop(self);
        std::future::ready(Ok(()))
    }
}
