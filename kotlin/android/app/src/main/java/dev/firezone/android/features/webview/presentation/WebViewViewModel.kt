package dev.firezone.android.features.webview.presentation

import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.features.webview.domain.SaveDeepLinkUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

@HiltViewModel
internal class WebViewViewModel @Inject constructor(
    private val getConfigUseCase: GetConfigUseCase,
    private val saveDeepLinkUseCase: SaveDeepLinkUseCase,
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<WebViewViewAction>()
    val actionLiveData: LiveData<WebViewViewAction> = actionMutableLiveData

    fun onSaveToken(value: String) {
        viewModelScope.launch {
            saveDeepLinkUseCase.invoke(value.substringAfterLast("="))
                .catch {
                    Log.e("Error", it.message.toString())
                }
                .collect {}
        }
    }

    fun onGetPortalUrl() {
        viewModelScope.launch {
            getConfigUseCase.invoke()
                .catch {
                    actionMutableLiveData.postValue(WebViewViewAction.ShowError)
                }
                .collect {
                    actionMutableLiveData.postValue(
                        WebViewViewAction.FillPortalUrl(
                            url = "${it.portalUrl}/auth"
                        )
                    )
                }
        }
    }
}
