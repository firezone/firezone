package dev.firezone.android.features.webview.presentation

internal sealed class WebViewViewAction {

    data class FillPortalUrl(val url: String) : WebViewViewAction()

    object ShowError : WebViewViewAction()
}
