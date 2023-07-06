package dev.firezone.android.features.splash.data

import dev.firezone.android.core.data.Config
import kotlinx.coroutines.flow.Flow

internal interface SplashRepository {
    fun getConfig(): Flow<Config>
}
