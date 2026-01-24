//
//  main.swift
//  FirezoneCLI
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import FirezoneKit
import NetworkExtension

@main
struct FirezoneCLI {
  static func main() async throws {
    let arguments = CommandLine.arguments
    
    guard arguments.count > 1 else {
      printUsage()
      exit(1)
    }
    
    let command = arguments[1]
    
    switch command {
    case "connect":
      try await connect()
    case "disconnect":
      try await disconnect()
    case "status":
      try await status()
    case "version":
      printVersion()
    case "help", "--help", "-h":
      printUsage()
    default:
      print("Unknown command: \(command)")
      printUsage()
      exit(1)
    }
  }
  
  static func printUsage() {
    print("""
    Firezone CLI - Headless VPN Client
    
    Usage: firezone-cli <command>
    
    Commands:
      connect     Start the VPN tunnel
      disconnect  Stop the VPN tunnel
      status      Show tunnel status
      version     Show version information
      help        Show this help message
    
    Environment Variables:
      FIREZONE_TOKEN    Service account token
      FIREZONE_ID       Device identifier
      FIREZONE_API_URL  API URL (default: wss://api.firezone.dev/)
    
    Note: This CLI uses NetworkExtension and does not require root privileges.
    """)
  }
  
  static func printVersion() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    print("Firezone CLI version \(version) (build \(build))")
  }
  
  static func connect() async throws {
    print("Starting VPN tunnel...")
    
    // Get configuration from environment
    guard let token = ProcessInfo.processInfo.environment["FIREZONE_TOKEN"] else {
      print("Error: FIREZONE_TOKEN environment variable not set")
      exit(1)
    }
    
    guard let deviceId = ProcessInfo.processInfo.environment["FIREZONE_ID"] else {
      print("Error: FIREZONE_ID environment variable not set")
      exit(1)
    }
    
    let apiURL = ProcessInfo.processInfo.environment["FIREZONE_API_URL"] ?? "wss://api.firezone.dev/"
    
    // Create tunnel configuration
    let configuration = TunnelConfiguration(
      apiURL: apiURL,
      accountSlug: "default", // TODO: Make this configurable
      logFilter: "info",
      internetResourceEnabled: false
    )
    
    // Use NETunnelProviderManager to start the tunnel
    let manager = NETunnelProviderManager()
    
    // Load existing configuration or create new one
    try await manager.loadFromPreferences()
    
    // Configure the tunnel
    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerBundleIdentifier = "dev.firezone.client.network-extension"
    protocolConfiguration.serverAddress = apiURL
    
    // Store token and device ID for the network extension
    protocolConfiguration.providerConfiguration = [
      "token": token,
      "firezoneId": deviceId
    ]
    
    manager.protocolConfiguration = protocolConfiguration
    manager.isEnabled = true
    manager.localizedDescription = "Firezone CLI"
    
    // Save configuration
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
    
    // Start the tunnel
    do {
      try manager.connection.startVPNTunnel()
      print("VPN tunnel started successfully")
      
      // Keep the process running to maintain the tunnel
      // In a real implementation, this would need proper signal handling
      print("Tunnel is running. Press Ctrl+C to stop.")
      
      // Wait indefinitely
      try await Task.sleep(for: .seconds(Int.max))
    } catch {
      print("Failed to start VPN tunnel: \(error)")
      exit(1)
    }
  }
  
  static func disconnect() async throws {
    print("Stopping VPN tunnel...")
    
    let manager = NETunnelProviderManager()
    try await manager.loadFromPreferences()
    
    manager.connection.stopVPNTunnel()
    print("VPN tunnel stopped")
  }
  
  static func status() async throws {
    let manager = NETunnelProviderManager()
    try await manager.loadFromPreferences()
    
    let connection = manager.connection
    let status = connection.status
    
    let statusString: String
    switch status {
    case .invalid:
      statusString = "Invalid"
    case .disconnected:
      statusString = "Disconnected"
    case .connecting:
      statusString = "Connecting"
    case .connected:
      statusString = "Connected"
    case .reasserting:
      statusString = "Reasserting"
    case .disconnecting:
      statusString = "Disconnecting"
    @unknown default:
      statusString = "Unknown"
    }
    
    print("Tunnel status: \(statusString)")
    
    if let connectedDate = connection.connectedDate {
      print("Connected since: \(connectedDate)")
    }
  }
}
