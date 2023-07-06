package dev.firezone.android.features.splash.domain

import android.content.SharedPreferences
import dev.firezone.android.core.data.Config
import dev.firezone.android.features.splash.data.SplashRepository
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

private const val PORTAL_URL_KEY = "portalUrl"
private const val IS_CONNECTED_KEY = "isConnected"
private const val JWT_KEY = "jwt"

internal class SplashRepositoryImpl @Inject constructor(
    private val coroutineDispatcher: CoroutineDispatcher,
    private val sharedPreferences: SharedPreferences
) : SplashRepository {

    override fun getConfig(): Flow<Config> = flow {
        emit(
            Config(
                portalUrl = sharedPreferences.getString(PORTAL_URL_KEY, null),
                isConnected = sharedPreferences.getBoolean(IS_CONNECTED_KEY, false),
                jwt = sharedPreferences.getString(JWT_KEY, null),
            )
        )
    }.flowOn(coroutineDispatcher)
}
