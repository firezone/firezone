// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.di

import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import dagger.Module
import dagger.Provides
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import dev.firezone.android.core.data.Repository
import dev.firezone.android.tunnel.TestRestrictions
import kotlinx.coroutines.CoroutineDispatcher
import javax.inject.Singleton

@Module
@TestInstallIn(
    components = [SingletonComponent::class],
    replaces = [DataModule::class],
)
object TestDataModule {
    // The real restrictions come from `RestrictionsManager`, which stays empty until a device
    // owner sets them. Tests write into this bundle instead to stand in for a managed config.
    @Provides
    internal fun provideApplicationRestrictions(): Bundle = TestRestrictions.bundle

    @Provides
    @Singleton
    internal fun provideRepository(
        @ApplicationContext context: Context,
        @IoDispatcher coroutineDispatcher: CoroutineDispatcher,
        sharedPreferences: SharedPreferences,
    ): Repository = Repository(context, coroutineDispatcher, sharedPreferences)
}
