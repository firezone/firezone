//
//  ConnlibUniFfi.swift
//  FirezoneNetworkExtension
//
//  This file provides a clean import for UniFFI types when UNIFFI is defined
//

#if UNIFFI

  // The connlib.swift generated file should be included in the project
  // and will be available in the same module namespace.
  // This file just helps organize the imports.

  // If you're getting compilation errors about missing types like Session, Event, etc.,
  // make sure:
  // 1. connlib.swift is added to the FirezoneNetworkExtension target in Xcode
  // 2. connlibFFI.h is accessible via the bridging header
  // 3. The UNIFFI compiler flag is set in build settings

#endif
