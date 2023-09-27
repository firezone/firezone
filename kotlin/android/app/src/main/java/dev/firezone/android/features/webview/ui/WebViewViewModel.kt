/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.webview.ui

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import javax.inject.Inject

@HiltViewModel
internal class WebViewViewModel @Inject constructor(
    private val getConfigUseCase: GetConfigUseCase,
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<ViewAction>()
    val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

    internal sealed class ViewAction {
        object ShowError : ViewAction()
    }
}
