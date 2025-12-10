// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.di

import dagger.Module
import dagger.Provides
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import dev.firezone.android.core.ApplicationMode

@Module
@TestInstallIn(
    components = [SingletonComponent::class],
    replaces = [RuntimeModule::class],
)
object TestRuntimeModule {
    @Provides
    internal fun provideApplicationMode() = ApplicationMode.TESTING
}
