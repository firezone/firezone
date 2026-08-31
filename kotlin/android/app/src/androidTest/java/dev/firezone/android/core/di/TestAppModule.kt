// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.di

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.content.res.Resources
import dagger.Module
import dagger.Provides
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import javax.inject.Singleton

@Module
@TestInstallIn(
    components = [SingletonComponent::class],
    replaces = [AppModule::class],
)
object TestAppModule {
    @Provides
    internal fun provideContext(app: Application): Context = app.applicationContext

    @Provides
    internal fun provideResources(app: Application): Resources = app.resources

    // Plain preferences rather than the encrypted ones: tests need to wipe them between runs,
    // and nothing here is worth a keystore round-trip.
    @Provides
    @Singleton
    internal fun provideSharedPreferences(app: Application): SharedPreferences =
        app.getSharedPreferences("test_preferences", Context.MODE_PRIVATE)
}
