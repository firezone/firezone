// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android

/**
 * Marks tests that need the test DPC in `dpc/` to own the device.
 *
 * Ownership is the one thing a test cannot arrange for itself, so CI provisions a dedicated
 * emulator and runs these there (the `managed` suite), keeping them out of every other device
 * (`--notAnnotation` in the `unmanaged` suite).
 */
@Retention(AnnotationRetention.RUNTIME)
@Target(AnnotationTarget.CLASS, AnnotationTarget.FUNCTION)
annotation class RequiresManagedDevice
