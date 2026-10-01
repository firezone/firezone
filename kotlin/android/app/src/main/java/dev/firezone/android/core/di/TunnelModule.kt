// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.di

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.core.DebugOverrides
import dev.firezone.android.tunnel.SessionFactory
import dev.firezone.android.tunnel.TunnelConnection
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.TunnelSession
import uniffi.connlib.SessionInterface
import uniffi.connlib.connectAndroid

@Module
@InstallIn(SingletonComponent::class)
object TunnelModule {
    @Provides
    internal fun provideSessionFactory(): SessionFactory =
        DebugOverrides.sessionFactory ?: SessionFactory { config, tlsIdentity ->
            val (session, events) =
                connectAndroid(
                    config = config,
                    protectSocket = TunnelService.protectSocketCallback,
                    tlsIdentity = tlsIdentity,
                )

            TunnelConnection(
                object : TunnelSession, SessionInterface by session {
                    override fun close() = session.close()
                },
                events,
            )
        }
}
