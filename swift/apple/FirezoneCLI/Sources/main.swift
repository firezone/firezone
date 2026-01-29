//
//  main.swift
//  FirezoneCLI
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import FirezoneKit
import NetworkExtension

#if os(macOS)
  import SystemExtensions
#endif

@main
struct FirezoneCLI {
  static func main() async throws {
    let arguments = CommandLine.arguments
    
    // If no subcommand is provided, default behavior is to connect
    if arguments.count == 1 {
      try await connect()
      return
    }
    
    let command = arguments[1]
    
    switch command {
    case "sign-in":
      try await signIn(arguments: Array(arguments.dropFirst(2)))
    case "sign-out":
      try await signOut()
    case "version", "--version", "-v":
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
    Firezone - Headless ZTNA Client
    
    Usage: firezone-cli [subcommand] [options]
    
    When run without a subcommand, connects to Firezone and starts the tunnel.
    
    Subcommands:
      sign-in          Sign in via browser-based authentication
      sign-out         Sign out by removing the stored token
      version          Show version information
      help             Show this help message
    
    Environment Variables:
      FIREZONE_TOKEN          Service account token (used if no stored token)
      FIREZONE_ID             Device identifier (auto-generated if not set)
      FIREZONE_API_URL        API URL (default: wss://api.firezone.dev/)
      FIREZONE_AUTH_BASE_URL  Auth base URL for sign-in (default: https://app.firezone.dev)
      FIREZONE_ACCOUNT_SLUG   Account slug for sign-in
      FIREZONE_NAME           Friendly name for this device
    
    Examples:
      firezone-cli                                    # Connect (default action)
      firezone-cli sign-in                            # Interactive sign-in
      firezone-cli sign-out                           # Sign out
      firezone-cli version                            # Show version
    Note: This CLI uses NetworkExtension and does not require root privileges.
    """)
  }
  
  static func printVersion() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    print("Firezone CLI version \(version) (build \(build))")
  }
  
  static func signIn(arguments: [String]) async throws {
    print("\n==========================================================================")
    print("Firezone Headless Client - Browser Authentication")
    print("==========================================================================\n")
    
    let authBaseURL = ProcessInfo.processInfo.environment["FIREZONE_AUTH_BASE_URL"] 
      ?? "https://app.firezone.dev"
    let accountSlug = ProcessInfo.processInfo.environment["FIREZONE_ACCOUNT_SLUG"]
    
    var authURL = URL(string: authBaseURL)!
    if let slug = accountSlug {
      authURL = authURL.appendingPathComponent(slug)
    }
    
    // Add query parameter to indicate this is headless-client auth
    var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
    var queryItems = components.queryItems ?? []
    queryItems.append(URLQueryItem(name: "as", value: "headless-client"))
    components.queryItems = queryItems
    authURL = components.url!
    
    print("To sign in to Firezone, please follow these steps:\n")
    print("1. Open the following URL in your web browser:\n")
    print("   \(authURL)\n")
    print("2. Complete the sign-in process in your browser")
    print("3. Copy the token displayed in the browser")
    print("4. Return to this terminal and paste the token below\n")
    print("==========================================================================\n")
    
    print("Enter the token from your browser: ", terminator: "")
    fflush(stdout)
    
    guard let token = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
      print("\nError: No token provided")
      exit(1)
    }
    
    // Validate token length (minimum 64 characters like Linux/Windows)
    guard token.count >= 64 else {
      print("\nError: Token appears to be invalid (too short)")
      exit(1)
    }
    
    // Store token securely in Keychain
    let tokenObj = Token(token)
    do {
      try tokenObj.save()
      print("\n✓ Token saved successfully")
      print("You can now run 'firezone-cli' to connect")
    } catch {
      print("\nError saving token: \(error)")
      exit(1)
    }
  }
  
  static func signOut() async throws {
    print("Signing out...")
    
    do {
      try Token.delete()
      print("✓ Token removed successfully")
    } catch {
      print("Error removing token: \(error)")
      exit(1)
    }
  }
  
  static func connect() async throws {
    print("Starting VPN tunnel...")
    
    // Try to load token from Keychain first, then environment
    var token: Token?
    do {
      token = try Token.load()
    } catch {
      // Token not in Keychain, try environment variable
      if let tokenString = ProcessInfo.processInfo.environment["FIREZONE_TOKEN"] {
        token = Token(tokenString)
      }
    }
    
    guard let token = token else {
      print("Error: No token found")
      print("Please run 'firezone-cli sign-in' to authenticate")
      print("Or set the FIREZONE_TOKEN environment variable")
      exit(1)
    }
    
    // Get or generate device ID
    let deviceId: String
    if let envDeviceId = ProcessInfo.processInfo.environment["FIREZONE_ID"] {
      deviceId = envDeviceId
    } else {
      // Try to load from UserDefaults or generate new one
      if let savedId = UserDefaults.standard.string(forKey: "firezoneId") {
        deviceId = savedId
      } else {
        deviceId = UUID().uuidString
        UserDefaults.standard.set(deviceId, forKey: "firezoneId")
      }
    }
    
    let apiURL = ProcessInfo.processInfo.environment["FIREZONE_API_URL"] ?? "wss://api.firezone.dev/"
    
    #if os(macOS)
      // Install system extension if needed
      print("Checking system extension...")
      let manager = SystemExtensionManager()
      let status = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in
        manager.sendRequest(
          requestType: .check,
          identifier: VPNConfigurationManager.bundleIdentifier,
          continuation: continuation
        )
      }
      
      if status == .needsInstall || status == .needsReplacement {
        print("Installing system extension...")
        print("You may be prompted to allow the system extension in System Settings.")
        let _ = try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in
          manager.sendRequest(
            requestType: .install,
            identifier: VPNConfigurationManager.bundleIdentifier,
            continuation: continuation
          )
        }
        print("✓ System extension installed")
      } else {
        print("✓ System extension already installed")
      }
    #endif
    
    // Load or create VPN configuration
    var vpnManager = try await VPNConfigurationManager.load()
    if vpnManager == nil {
      print("Creating VPN configuration...")
      vpnManager = try await VPNConfigurationManager()
      print("✓ VPN configuration created")
    }
    
    guard let vpnManager = vpnManager else {
      print("Error: Failed to initialize VPN manager")
      exit(1)
    }
    
    // Enable the VPN configuration
    try await vpnManager.enable()
    
    guard let session = vpnManager.session() else {
      print("Error: Failed to get VPN session")
      exit(1)
    }
    
    // Start the tunnel using IPCClient like the GUI app does
    print("Starting tunnel...")
    try IPCClient.start(session: session, token: token.description)
    print("✓ Tunnel started successfully")
    
    // Keep the process running to maintain the tunnel
    print("Tunnel is running. Press Ctrl+C to stop.")
    
    // Set up signal handler for graceful shutdown
    signal(SIGINT) { _ in
      print("\nReceived interrupt signal, shutting down...")
      exit(0)
    }
    
    signal(SIGTERM) { _ in
      print("\nReceived termination signal, shutting down...")
      exit(0)
    }
    
    // Wait indefinitely
    try await Task.sleep(for: .seconds(Int.max))
  }
}

