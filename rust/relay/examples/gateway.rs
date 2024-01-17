use anyhow::Result;
use redis::AsyncCommands;
use std::net::SocketAddr;
use std::time::Duration;
use tokio::net::UdpSocket;
use webrtc::turn::Error;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let socket = UdpSocket::bind("127.0.0.1:0").await?;
    let listening_addr = socket.local_addr()?;

    println!("Our listening address is {listening_addr}");

    let redis_client = redis::Client::open("redis://localhost:6379")?;
    let mut redis_connection = redis_client.get_async_connection().await?;

    redis_connection
        .rpush("gateway_addr", listening_addr.to_string())
        .await?;
    let relay_addr = redis_connection
        .blpop::<_, (String, String)>("client_relay_addr", 10.0)
        .await?
        .1
        .parse::<SocketAddr>()?;

    println!("Client's relay address is {relay_addr}");

    tokio::time::timeout(Duration::from_secs(5), ping_pong(socket, relay_addr)).await??;

    Ok(())
}

async fn ping_pong(socket: UdpSocket, relay_addr: SocketAddr) -> Result<(), Error> {
    for _ in 0..1000 {
        let ping = rand::random::<[u8; 32]>();

        socket.send_to(&ping, relay_addr).await?;

        println!("Sent ping to client: {}", hex::encode(ping));

        let mut pong = [0u8; 32];
        socket.recv_from(&mut pong).await?;

        println!("Received pong from client: {}", hex::encode(pong));

        assert_eq!(ping, pong);
    }

    Ok(())
}
