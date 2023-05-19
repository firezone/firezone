use anyhow::Result;
use redis::AsyncCommands;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UdpSocket;
use webrtc::turn::client::*;
use webrtc::turn::Error;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let socket = Arc::new(UdpSocket::bind("0.0.0.0:0").await?);
    let turn_client = new_turn_client(socket.clone()).await?;

    let remote_addr = turn_client.send_binding_request().await?;

    println!("Our external address is {remote_addr}");

    let redis_client = redis::Client::open("redis://localhost:6379")?;
    let mut redis_connection = redis_client.get_async_connection().await?;

    redis_connection
        .rpush("gateway_addr", remote_addr.to_string())
        .await?;
    let relay_addr = redis_connection
        .blpop::<_, (String, String)>("client_relay_addr", 10)
        .await?
        .1
        .parse::<SocketAddr>()?;

    println!("Client's relay address is {remote_addr}");

    tokio::time::timeout(Duration::from_secs(5), ping_pong(socket, relay_addr)).await??;

    Ok(())
}

async fn ping_pong(socket: Arc<UdpSocket>, relay_addr: SocketAddr) -> Result<(), Error> {
    for _ in 0..5 {
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

async fn new_turn_client(conn: Arc<UdpSocket>) -> Result<Client, Error> {
    let client = Client::new(ClientConfig {
        stun_serv_addr: "localhost:3478".to_owned(),
        turn_serv_addr: "localhost:3478".to_owned(),
        username: "test".to_owned(),
        password: "test".to_owned(),
        realm: "test".to_owned(),
        software: String::new(),
        rto_in_ms: 0,
        conn,
        vnet: None,
    })
    .await?;

    client.listen().await?;
    Ok(client)
}
