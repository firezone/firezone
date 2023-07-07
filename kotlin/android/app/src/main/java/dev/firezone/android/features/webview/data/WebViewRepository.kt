package dev.firezone.android.features.webview.data

import kotlinx.coroutines.flow.Flow

internal interface WebViewRepository {

    fun saveDeepLink(value: String): Flow<Unit>
}
