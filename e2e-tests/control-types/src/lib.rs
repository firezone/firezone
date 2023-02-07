use std::fmt::Display;
use std::net::SocketAddr;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    IoError(#[from] std::io::Error),
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub enum Command {
    Send(SendParams),
    Listen(ListenParams),
}

impl Command {
    pub fn send(address: SocketAddr, protocol: Protocol, message: Vec<u8>) -> Self {
        Command::Send(SendParams {
            address,
            protocol,
            message,
        })
    }

    pub fn listen(address: SocketAddr, protocol: Protocol) -> Self {
        Command::Listen(ListenParams { address, protocol })
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct SendParams {
    address: SocketAddr,
    protocol: Protocol,
    message: Vec<u8>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Tcp,
    Udp,
}

impl Display for Protocol {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Protocol::Tcp => write!(f, "TCP"),
            Protocol::Udp => write!(f, "UDP"),
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ListenParams {
    address: SocketAddr,
    protocol: Protocol,
}

pub type CommResult = Result<Vec<u8>, CommError>;

#[derive(Debug, Error, Deserialize, Serialize)]
pub enum CommError {
    #[error("Error with communication")]
    IoError,
    #[error("Timedout while waiting for connect, connection probably blocked")]
    Timeout,
}

impl From<tokio::time::error::Elapsed> for CommError {
    fn from(_: tokio::time::error::Elapsed) -> Self {
        CommError::Timeout
    }
}

impl From<std::io::Error> for CommError {
    fn from(_: std::io::Error) -> Self {
        Self::IoError
    }
}

impl Command {
    pub async fn execute_command(&self) -> CommResult {
        match self {
            Command::Send(send_params) => send(send_params).await,
            Command::Listen(listen_params) => listen(listen_params).await,
        }
    }
}

pub async fn send(send: &SendParams) -> CommResult {
    match send.protocol {
        Protocol::Tcp => {
            let mut stream =
                tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(send.address)).await??;
            stream.write_all(&send.message).await?;
            stream.shutdown().await?;
        }
        Protocol::Udp => {
            let sock = UdpSocket::bind("0.0.0.0:0").await?;
            sock.send_to(&send.message, send.address).await?;
        }
    }
    Ok(Vec::new())
}

pub async fn listen(listen: &ListenParams) -> CommResult {
    let result = match listen.protocol {
        Protocol::Tcp => {
            let listener = TcpListener::bind(listen.address).await?;
            let (mut stream, _addr) = listener.accept().await?;
            let mut buff = Vec::new();
            stream.read_to_end(&mut buff).await?;
            buff
        }
        Protocol::Udp => {
            let listener = UdpSocket::bind(listen.address).await?;
            let mut buff = vec![0u8; 16];
            listener.recv_from(&mut buff).await?;
            buff
        }
    };
    Ok(result)
}
