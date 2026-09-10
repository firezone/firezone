// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.di

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.core.ApplicationMode
import dev.firezone.android.core.DebugOverrides

@Module
@InstallIn(SingletonComponent::class)
object RuntimeModule {
    // Mocking connlib leaves no tunnel to establish, so it leaves no VPN permission to ask for.
    @Provides
    internal fun provideApplicationMode() =
        if (DebugOverrides.sessionFactory != null) {
            ApplicationMode.MOCK
        } else {
            ApplicationMode.NORMAL
        }
}
