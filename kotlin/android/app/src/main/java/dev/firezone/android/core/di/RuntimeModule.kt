// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.di

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.core.ApplicationMode

@Module
@InstallIn(SingletonComponent::class)
object RuntimeModule {
    @Provides
    internal fun provideApplicationMode() = ApplicationMode.NORMAL
}
