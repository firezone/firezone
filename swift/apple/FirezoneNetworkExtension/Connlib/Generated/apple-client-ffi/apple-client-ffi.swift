@_cdecl("__swift_bridge__$CallbackHandler$on_set_interface_config")
func __swift_bridge__CallbackHandler_on_set_interface_config(
  _ this: UnsafeMutableRawPointer, _ tunnelAddressIPv4: UnsafeMutableRawPointer,
  _ tunnelAddressIPv6: UnsafeMutableRawPointer, _ searchDomain: UnsafeMutableRawPointer?,
  _ dnsAddresses: UnsafeMutableRawPointer, _ routeListv4: UnsafeMutableRawPointer,
  _ routeListv6: UnsafeMutableRawPointer
) {
  Unmanaged<CallbackHandler>.fromOpaque(this).takeUnretainedValue().onSetInterfaceConfig(
    tunnelAddressIPv4: RustString(ptr: tunnelAddressIPv4),
    tunnelAddressIPv6: RustString(ptr: tunnelAddressIPv6),
    searchDomain: {
      let val = searchDomain
      if val != nil { return RustString(ptr: val!) } else { return nil }
    }(), dnsAddresses: RustString(ptr: dnsAddresses), routeListv4: RustString(ptr: routeListv4),
    routeListv6: RustString(ptr: routeListv6))
}

@_cdecl("__swift_bridge__$CallbackHandler$on_update_resources")
func __swift_bridge__CallbackHandler_on_update_resources(
  _ this: UnsafeMutableRawPointer, _ resourceList: UnsafeMutableRawPointer
) {
  Unmanaged<CallbackHandler>.fromOpaque(this).takeUnretainedValue().onUpdateResources(
    resourceList: RustString(ptr: resourceList))
}

@_cdecl("__swift_bridge__$CallbackHandler$on_disconnect")
func __swift_bridge__CallbackHandler_on_disconnect(
  _ this: UnsafeMutableRawPointer, _ error: UnsafeMutableRawPointer
) {
  Unmanaged<CallbackHandler>.fromOpaque(this).takeUnretainedValue().onDisconnect(
    error: DisconnectError(ptr: error))
}

public class DisconnectError: DisconnectErrorRefMut {
  var isOwned: Bool = true

  public override init(ptr: UnsafeMutableRawPointer) {
    super.init(ptr: ptr)
  }

  deinit {
    if isOwned {
      __swift_bridge__$DisconnectError$_free(ptr)
    }
  }
}
public class DisconnectErrorRefMut: DisconnectErrorRef {
  public override init(ptr: UnsafeMutableRawPointer) {
    super.init(ptr: ptr)
  }
}
public class DisconnectErrorRef {
  var ptr: UnsafeMutableRawPointer

  public init(ptr: UnsafeMutableRawPointer) {
    self.ptr = ptr
  }
}
extension DisconnectErrorRef {
  public func isAuthenticationError() -> Bool {
    __swift_bridge__$DisconnectError$is_authentication_error(ptr)
  }

  public func toString() -> RustString {
    RustString(ptr: __swift_bridge__$DisconnectError$to_string(ptr))
  }
}
extension DisconnectError: Vectorizable {
  public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
    __swift_bridge__$Vec_DisconnectError$new()
  }

  public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
    __swift_bridge__$Vec_DisconnectError$drop(vecPtr)
  }

  public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: DisconnectError) {
    __swift_bridge__$Vec_DisconnectError$push(
      vecPtr,
      {
        value.isOwned = false
        return value.ptr
      }())
  }

  public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Self? {
    let pointer = __swift_bridge__$Vec_DisconnectError$pop(vecPtr)
    if pointer == nil {
      return nil
    } else {
      return (DisconnectError(ptr: pointer!) as! Self)
    }
  }

  public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt)
    -> DisconnectErrorRef?
  {
    let pointer = __swift_bridge__$Vec_DisconnectError$get(vecPtr, index)
    if pointer == nil {
      return nil
    } else {
      return DisconnectErrorRef(ptr: pointer!)
    }
  }

  public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt)
    -> DisconnectErrorRefMut?
  {
    let pointer = __swift_bridge__$Vec_DisconnectError$get_mut(vecPtr, index)
    if pointer == nil {
      return nil
    } else {
      return DisconnectErrorRefMut(ptr: pointer!)
    }
  }

  public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<
    DisconnectErrorRef
  > {
    UnsafePointer<DisconnectErrorRef>(
      OpaquePointer(__swift_bridge__$Vec_DisconnectError$as_ptr(vecPtr)))
  }

  public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
    __swift_bridge__$Vec_DisconnectError$len(vecPtr)
  }
}

public class WrappedSession: WrappedSessionRefMut {
  var isOwned: Bool = true

  public override init(ptr: UnsafeMutableRawPointer) {
    super.init(ptr: ptr)
  }

  deinit {
    if isOwned {
      __swift_bridge__$WrappedSession$_free(ptr)
    }
  }
}
extension WrappedSession {
  class public func connect<GenericIntoRustString: IntoRustString>(
    _ api_url: GenericIntoRustString, _ token: GenericIntoRustString,
    _ device_id: GenericIntoRustString, _ account_slug: GenericIntoRustString,
    _ device_name_override: GenericIntoRustString?, _ os_version_override: GenericIntoRustString?,
    _ log_dir: GenericIntoRustString, _ log_filter: GenericIntoRustString,
    _ callback_handler: CallbackHandler, _ device_info: GenericIntoRustString
  ) throws -> WrappedSession {
    try {
      let val = __swift_bridge__$WrappedSession$connect(
        {
          let rustString = api_url.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }(),
        {
          let rustString = token.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }(),
        {
          let rustString = device_id.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }(),
        {
          let rustString = account_slug.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }(),
        {
          if let rustString = optionalStringIntoRustString(device_name_override) {
            rustString.isOwned = false
            return rustString.ptr
          } else {
            return nil
          }
        }(),
        {
          if let rustString = optionalStringIntoRustString(os_version_override) {
            rustString.isOwned = false
            return rustString.ptr
          } else {
            return nil
          }
        }(),
        {
          let rustString = log_dir.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }(),
        {
          let rustString = log_filter.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }(), Unmanaged.passRetained(callback_handler).toOpaque(),
        {
          let rustString = device_info.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }())
      if val.is_ok {
        return WrappedSession(ptr: val.ok_or_err!)
      } else {
        throw RustString(ptr: val.ok_or_err!)
      }
    }()
  }
}
public class WrappedSessionRefMut: WrappedSessionRef {
  public override init(ptr: UnsafeMutableRawPointer) {
    super.init(ptr: ptr)
  }
}
extension WrappedSessionRefMut {
  public func reset() {
    __swift_bridge__$WrappedSession$reset(ptr)
  }

  public func setDns<GenericIntoRustString: IntoRustString>(_ dns_servers: GenericIntoRustString)
    throws
  {
    try {
      let val = __swift_bridge__$WrappedSession$set_dns(
        ptr,
        {
          let rustString = dns_servers.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }())
      if val != nil { throw RustString(ptr: val!) } else { return }
    }()
  }

  public func setDisabledResources<GenericIntoRustString: IntoRustString>(
    _ disabled_resources: GenericIntoRustString
  ) throws {
    try {
      let val = __swift_bridge__$WrappedSession$set_disabled_resources(
        ptr,
        {
          let rustString = disabled_resources.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }())
      if val != nil { throw RustString(ptr: val!) } else { return }
    }()
  }

  public func setLogDirectives<GenericIntoRustString: IntoRustString>(
    _ directives: GenericIntoRustString
  ) throws {
    try {
      let val = __swift_bridge__$WrappedSession$set_log_directives(
        ptr,
        {
          let rustString = directives.intoRustString()
          rustString.isOwned = false
          return rustString.ptr
        }())
      if val != nil { throw RustString(ptr: val!) } else { return }
    }()
  }
}
public class WrappedSessionRef {
  var ptr: UnsafeMutableRawPointer

  public init(ptr: UnsafeMutableRawPointer) {
    self.ptr = ptr
  }
}
extension WrappedSession: Vectorizable {
  public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
    __swift_bridge__$Vec_WrappedSession$new()
  }

  public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
    __swift_bridge__$Vec_WrappedSession$drop(vecPtr)
  }

  public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: WrappedSession) {
    __swift_bridge__$Vec_WrappedSession$push(
      vecPtr,
      {
        value.isOwned = false
        return value.ptr
      }())
  }

  public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Self? {
    let pointer = __swift_bridge__$Vec_WrappedSession$pop(vecPtr)
    if pointer == nil {
      return nil
    } else {
      return (WrappedSession(ptr: pointer!) as! Self)
    }
  }

  public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt)
    -> WrappedSessionRef?
  {
    let pointer = __swift_bridge__$Vec_WrappedSession$get(vecPtr, index)
    if pointer == nil {
      return nil
    } else {
      return WrappedSessionRef(ptr: pointer!)
    }
  }

  public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt)
    -> WrappedSessionRefMut?
  {
    let pointer = __swift_bridge__$Vec_WrappedSession$get_mut(vecPtr, index)
    if pointer == nil {
      return nil
    } else {
      return WrappedSessionRefMut(ptr: pointer!)
    }
  }

  public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<
    WrappedSessionRef
  > {
    UnsafePointer<WrappedSessionRef>(
      OpaquePointer(__swift_bridge__$Vec_WrappedSession$as_ptr(vecPtr)))
  }

  public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
    __swift_bridge__$Vec_WrappedSession$len(vecPtr)
  }
}

@_cdecl("__swift_bridge__$CallbackHandler$_free")
func __swift_bridge__CallbackHandler__free(ptr: UnsafeMutableRawPointer) {
  let _ = Unmanaged<CallbackHandler>.fromOpaque(ptr).takeRetainedValue()
}
