package dev.firezone.android.core.di

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.content.res.Resources
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.squareup.moshi.Moshi
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.domain.preference.SaveIsConnectedUseCase
import dev.firezone.android.tunnel.TunnelManager

internal const val ENCRYPTED_SHARED_PREFERENCES = "encryptedSharedPreferences"

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    internal fun provideContext(app: Application): Context = app.applicationContext

    @Provides
    internal fun provideResources(app: Application): Resources = app.resources

    @Provides
    internal fun provideEncryptedSharedPreferences(app: Application): SharedPreferences =
        EncryptedSharedPreferences.create(
            app.applicationContext,
            ENCRYPTED_SHARED_PREFERENCES,
            MasterKey.Builder(app.applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )

    @Provides
    internal fun provideTunnelManager(
        @ApplicationContext appContext: Context,
        getConfigUseCase: GetConfigUseCase,
        saveIsConnectedUseCase: SaveIsConnectedUseCase,
        moshi: Moshi,
    ): TunnelManager = TunnelManager(appContext, getConfigUseCase, saveIsConnectedUseCase, moshi)
}
