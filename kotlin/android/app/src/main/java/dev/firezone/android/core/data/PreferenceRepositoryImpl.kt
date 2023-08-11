package dev.firezone.android.core.data

import android.content.SharedPreferences
import dev.firezone.android.core.data.model.Config
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

internal class PreferenceRepositoryImpl @Inject constructor(
    private val coroutineDispatcher: CoroutineDispatcher,
    private val sharedPreferences: SharedPreferences
) : PreferenceRepository {

    override fun getConfigSync(): Config = Config(
        portalUrl = sharedPreferences.getString(PORTAL_URL_KEY, null),
        isConnected = sharedPreferences.getBoolean(IS_CONNECTED_KEY, false),
        jwt = sharedPreferences.getString(JWT_KEY, null),
    )

    override fun getConfig(): Flow<Config> = flow {
        emit(getConfigSync())
    }.flowOn(coroutineDispatcher)

    override fun savePortalUrl(value: String): Flow<Unit> = flow {
        emit(
            sharedPreferences
                .edit()
                .putString(PORTAL_URL_KEY, value)
                .apply()
        )
    }.flowOn(coroutineDispatcher)

    override fun saveJWT(value: String): Flow<Unit> = flow {
        emit(
            sharedPreferences
                .edit()
                .putString(JWT_KEY, value)
                .apply()
        )
    }.flowOn(coroutineDispatcher)

    override fun saveIsConnectedSync(value: Boolean) {
        sharedPreferences
            .edit()
            .putBoolean(IS_CONNECTED_KEY, value)
            .apply()
    }

    override fun saveIsConnected(value: Boolean): Flow<Unit> = flow {
        emit(
            saveIsConnectedSync(value)
        )
    }.flowOn(coroutineDispatcher)

    override fun validateCsrfToken(value: String): Flow<Boolean> = flow {
        val token = sharedPreferences.getString(CSRF_KEY, "")
        emit(token == value)
    }.flowOn(coroutineDispatcher)

    companion object {
        private const val PORTAL_URL_KEY = "portalUrl"
        private const val IS_CONNECTED_KEY = "isConnected"
        private const val JWT_KEY = "jwt"
        private const val CSRF_KEY = "csrf"
    }
}
