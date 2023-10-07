/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.di

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.squareup.moshi.Moshi
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.tunnel.TunnelManager
import dev.firezone.android.tunnel.data.TunnelRepository
import dev.firezone.android.tunnel.data.TunnelRepositoryImpl
import javax.inject.Named
import javax.inject.Singleton

internal const val TUNNEL_ENCRYPTED_SHARED_PREFERENCES = "tunnelEncryptedSharedPreferences"

@Module
@InstallIn(SingletonComponent::class)
object TunnelModule {
    @Singleton
    @Provides
    internal fun provideTunnelRepository(
        @Named(TunnelRepository.TAG) sharedPreferences: SharedPreferences,
        moshi: Moshi,
    ): TunnelRepository = TunnelRepositoryImpl(sharedPreferences, moshi)

    @Provides
    @Named(TunnelRepository.TAG)
    internal fun provideTunnelEncryptedSharedPreferences(app: Application): SharedPreferences =
        EncryptedSharedPreferences.create(
            app.applicationContext,
            TUNNEL_ENCRYPTED_SHARED_PREFERENCES,
            MasterKey.Builder(app.applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    @Provides
    internal fun provideTunnelManager(
        @ApplicationContext appContext: Context,
        tunnelRepository: TunnelRepository,
        preferenceRepository: PreferenceRepository,
    ): TunnelManager = TunnelManager(appContext, tunnelRepository, preferenceRepository)
}
