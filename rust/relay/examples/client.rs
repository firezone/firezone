use anyhow::Result;
use redis::AsyncCommands;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UdpSocket;
use webrtc::turn::client::*;
use webrtc::turn::Error;
use webrtc::util::Conn;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let redis_client = redis::Client::open("redis://localhost:6379")?;
    let mut redis_connection = redis_client.get_async_connection().await?;

    let turn_client = new_turn_client().await?;

    let relay_conn = turn_client.allocate().await?;
    let relay_addr = relay_conn.local_addr()?;

    println!("Allocated relay address: {relay_addr}");

    let gateway_addr = redis_connection
        .blpop::<_, (String, String)>("gateway_addr", 10.0)
        .await?
        .1
        .parse::<SocketAddr>()?;

    println!("Retrieved gateway address: {gateway_addr}");

    // The webrtc-rs client has no concept of explicitly creating a channel.
    // Instead, it will implicitly create one when trying to send data to a remote.
    relay_conn.send_to(b"HOLEPUNCH", gateway_addr).await?;

    // `webrtc-ts` does not block on the creation of the channel binding.
    // Wait for some amount of time here to avoid race conditions.
    tokio::time::sleep(Duration::from_millis(10)).await;

    println!("Created channel to gateway");

    // Now that our relay connection is active, share the address with the gateway.
    redis_connection
        .rpush("client_relay_addr", relay_addr.to_string())
        .await?;

    println!("Pushed relay address to gateway");

    // The actual test:
    // Wait for an incoming packets and echo them back until the test harness kills us.

    loop {
        let mut buf = [0u8; 32];
        let (_, sender) = relay_conn.recv_from(&mut buf).await?;

        println!("Received buffer from {sender}: {}", hex::encode(buf));

        relay_conn.send_to(&buf, sender).await?;
    }
}

async fn new_turn_client() -> Result<Client, Error> {
    let client = Client::new(ClientConfig {
        stun_serv_addr: "localhost:3478".to_owned(),
        turn_serv_addr: "localhost:3478".to_owned(),
        username: "2000000000:client".to_owned(), // 2000000000 expires in 2033, plenty of time
        password: "+Qou8TSjw9q3JMnWET7MbFsQh/agwz/LURhpfX7a0hE".to_owned(),
        realm: "firezone".to_owned(),
        software: String::new(),
        rto_in_ms: 0,
        conn: Arc::new(UdpSocket::bind("127.0.0.1:0").await?),
        vnet: None,
    })
    .await?;

    client.listen().await?;
    Ok(client)
}
