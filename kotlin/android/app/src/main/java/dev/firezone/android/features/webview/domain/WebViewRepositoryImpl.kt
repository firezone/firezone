package dev.firezone.android.features.webview.domain

import android.content.SharedPreferences
import dev.firezone.android.features.webview.data.WebViewRepository
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

private const val DEEP_LINK_KEY = "deepLink"

internal class WebViewRepositoryImpl @Inject constructor(
    private val coroutineDispatcher: CoroutineDispatcher,
    private val sharedPreferences: SharedPreferences
) : WebViewRepository {

    override fun saveDeepLink(value: String): Flow<Unit> = flow {
        emit(
            sharedPreferences
                .edit()
                .putString(DEEP_LINK_KEY, value)
                .apply()
        )
    }.flowOn(coroutineDispatcher)
}
