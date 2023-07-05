package dev.firezone.android.features.webview.domain

import dev.firezone.android.features.webview.data.WebViewRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class SaveDeepLinkUseCase @Inject constructor(
    private val repository: WebViewRepository
) {
    operator fun invoke(value: String): Flow<Unit> = repository.saveDeepLink(value)
}
