//! Client session driven on its host's thread with externally completed packet I/O.

use crate::{
    EventStream, Session,
    eventloop::{DisconnectError, Eventloop},
};
pub type DrivenEvents = EventStream<
    futures::future::LocalBoxFuture<
        'static,
        Result<Result<(), DisconnectError>, tokio::task::JoinError>,
    >,
>;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{net::IpAddr, path::PathBuf, sync::Arc};
use tokio::sync::mpsc;
pub use tunnel::packet_io::completion::{
    CompletionIo, CompletionPort, Operation, Payload, ReceivedDatagram,
};

/// Starts the shared client event loop inside the current thread.
pub fn connect(
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    portal: PhoenixChannel<
        (),
        tunnel::messages::client::EgressMessages,
        tunnel::messages::client::IngressMessages,
        PublicKeyParam,
    >,
    is_internet_resource_active: bool,
    dns_servers: Vec<IpAddr>,
    flow_logs_dir: Option<PathBuf>,
    local_flow_logs: bool,
) -> (Session, DrivenEvents, CompletionPort) {
    let (packets, port) = CompletionIo::new();
    let (channel, cmd_rx) = mpsc::unbounded_channel();
    let event_stream =
        EventStream::new_local(move |resources, tun_config, connected_as, notifications| {
            Eventloop::with_packets(
                tcp_socket_factory,
                udp_socket_factory,
                is_internet_resource_active,
                dns_servers,
                flow_logs_dir,
                local_flow_logs,
                portal,
                cmd_rx,
                resources,
                tun_config,
                connected_as,
                notifications,
                packets,
            )
            .run()
        });
    (Session { channel }, event_stream, port)
}
