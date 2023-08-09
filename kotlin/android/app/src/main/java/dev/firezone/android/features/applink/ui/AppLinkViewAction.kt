package dev.firezone.android.features.applink.ui

internal sealed class AppLinkViewAction {

    object AuthFlowComplete : AppLinkViewAction()

    object ShowError : AppLinkViewAction()
}
