package dev.firezone.android.features.auth.ui

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.BuildConfig
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
                .firstOrNull() ?: throw Exception("config cannot be null")

            val csrfToken = getCsrfTokenUseCase()
                .firstOrNull() ?: throw Exception("csrfToken cannot be null")

            actionMutableLiveData.postValue(
                ViewAction.LaunchAuthFlow(
                    url = "$AUTH_URL${config.accountId}/sign_in?client_csrf_token=${csrfToken}&client_platform=android"
                )
            )
        }
    } catch (e: Exception) {
        actionMutableLiveData.postValue(ViewAction.ShowError)
    }

    companion object {
        val AUTH_URL = "${BuildConfig.AUTH_SCHEME}://${BuildConfig.AUTH_HOST}:${BuildConfig.AUTH_PORT}/"
    }

    internal sealed class ViewAction {

        data class LaunchAuthFlow(val url: String) : ViewAction()

        object AuthFlowComplete : ViewAction()

        object ShowError : ViewAction()
    }
}
