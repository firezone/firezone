package dev.firezone.android.features.auth.ui

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.auth.GetCsrfTokenUseCase
import javax.inject.Inject
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import java.lang.Exception

@HiltViewModel
internal class AuthViewModel @Inject constructor(
    private val getConfigUseCase: GetConfigUseCase,
    private val getCsrfTokenUseCase: GetCsrfTokenUseCase,
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<ViewAction>()
    val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

    fun startAuthFlow() = try {
        viewModelScope.launch {
            val config = getConfigUseCase()
                .firstOrNull() ?: throw Exception("Config cannot be null")

            val token = getCsrfTokenUseCase()
                .firstOrNull() ?: throw Exception("Token cannot be null")

            actionMutableLiveData.postValue(
                ViewAction.LaunchAuthFlow(
                    url = "${config.portalUrl}/sign_in?client_csrf_token=$token&client_platform=android"
                )
            )
        }
    } catch (e: Exception) {
        actionMutableLiveData.postValue(ViewAction.ShowError)
    }

    internal sealed class ViewAction {

        data class LaunchAuthFlow(val url: String) : ViewAction()

        object AuthFlowComplete : ViewAction()

        object ShowError : ViewAction()
    }
}
