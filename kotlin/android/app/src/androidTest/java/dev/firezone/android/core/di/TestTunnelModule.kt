// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.di

import dagger.Module
import dagger.Provides
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.SessionFactory

@Module
@TestInstallIn(
    components = [SingletonComponent::class],
    replaces = [TunnelModule::class],
)
object TestTunnelModule {
    @Provides
    internal fun provideSessionFactory(): SessionFactory = FakeSessionFactory
}
