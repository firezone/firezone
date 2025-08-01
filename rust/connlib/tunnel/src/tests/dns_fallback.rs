use std::time::Instant;

use dns_types::{Query, RecordType};

use crate::{
    client::ClientState,
    dns::ResolveStrategy,
};

/// Test that DNS queries for site-specific resources (SRV/TXT) are handled properly
/// when no gateway connection exists.
///
/// This addresses the issue where MongoDB connections fail because SRV queries
/// are buffered waiting for gateway connections that haven't been established yet.
#[test]
fn srv_query_strategy_when_gateway_not_connected() {
    let mut state = ClientState::new([0u8; 32], Instant::now());
    
    // Add a DNS resource
    let resource_id = connlib_model::ResourceId::from_u128(1);
    let added = state.add_resource(resource_id, "test.example.com".to_string(), Default::default());
    assert!(added, "Resource should be added successfully");

    // Create an SRV query for the DNS resource
    let query = Query::new(
        "test.example.com".parse().unwrap(),
        RecordType::SRV,
    );

    // Handle the DNS query - this should return RecurseSite
    let strategy = state.stub_resolver.handle(&query);
    
    // Verify that we get RecurseSite for the resource
    match strategy {
        ResolveStrategy::RecurseSite(resource) => {
            assert_eq!(resource, resource_id);
        }
        _ => panic!("Expected RecurseSite strategy for SRV query, got {:?}", strategy),
    }
}

/// Test that TXT queries also return RecurseSite
#[test]
fn txt_query_strategy_when_gateway_not_connected() {
    let mut state = ClientState::new([0u8; 32], Instant::now());
    
    // Add a DNS resource
    let resource_id = connlib_model::ResourceId::from_u128(1);
    let added = state.add_resource(resource_id, "test.example.com".to_string(), Default::default());
    assert!(added, "Resource should be added successfully");

    // Create a TXT query for the DNS resource
    let query = Query::new(
        "test.example.com".parse().unwrap(),
        RecordType::TXT,
    );

    // Handle the DNS query - this should return RecurseSite
    let strategy = state.stub_resolver.handle(&query);
    
    // Verify that we get RecurseSite for the resource
    match strategy {
        ResolveStrategy::RecurseSite(resource) => {
            assert_eq!(resource, resource_id);
        }
        _ => panic!("Expected RecurseSite strategy for TXT query, got {:?}", strategy),
    }
}

/// Test that A queries for DNS resources return LocalResponse
#[test] 
fn a_query_strategy_for_dns_resource() {
    let mut state = ClientState::new([0u8; 32], Instant::now());
    
    // Add a DNS resource
    let resource_id = connlib_model::ResourceId::from_u128(1);
    let added = state.add_resource(resource_id, "test.example.com".to_string(), Default::default());
    assert!(added, "Resource should be added successfully");

    // Create an A query for the DNS resource
    let query = Query::new(
        "test.example.com".parse().unwrap(),
        RecordType::A,
    );

    // Handle the DNS query - this should return LocalResponse with assigned IPs
    let strategy = state.stub_resolver.handle(&query);
    
    // Verify that we get LocalResponse for A query (not RecurseSite)
    match strategy {
        ResolveStrategy::LocalResponse(_response) => {
            // This is expected for A/AAAA queries - we assign proxy IPs
        }
        _ => panic!("Expected LocalResponse strategy for A query, got {:?}", strategy),
    }
}