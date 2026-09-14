// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.di

import dagger.Module
import dagger.Provides
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import dev.firezone.android.core.x509.FakeKeyChain
import dev.firezone.android.core.x509.KeyChain

@Module
@TestInstallIn(
    components = [SingletonComponent::class],
    replaces = [KeyChainModule::class],
)
object TestKeyChainModule {
    @Provides
    internal fun provideKeyChain(): KeyChain = FakeKeyChain
}
