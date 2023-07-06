package dev.firezone.android.features.applink.presentation

internal sealed class AppLinkViewAction {

    object AuthFlowComplete : AppLinkViewAction()

    object ShowError : AppLinkViewAction()
}
