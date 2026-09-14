// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.core.x509.KeyChain
import dev.firezone.android.core.x509.SystemKeyChain

@Module
@InstallIn(SingletonComponent::class)
object KeyChainModule {
    @Provides
    internal fun provideKeyChain(
        @ApplicationContext context: Context,
    ): KeyChain = SystemKeyChain(context)
}
