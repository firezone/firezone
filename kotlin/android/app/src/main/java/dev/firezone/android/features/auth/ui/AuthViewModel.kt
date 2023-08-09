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

    private val actionMutableLiveData = MutableLiveData<AuthViewAction>()
    val actionLiveData: LiveData<AuthViewAction> = actionMutableLiveData

    fun startAuthFlow() = try {
        viewModelScope.launch {
            val config = getConfigUseCase()
                .firstOrNull() ?: throw Exception("Config cannot be null")

            val token = getCsrfTokenUseCase()
                .firstOrNull() ?: throw Exception("Token cannot be null")

            actionMutableLiveData.postValue(
                AuthViewAction.LaunchAuthFlow(
                    url = "${config.portalUrl}/auth?client_csrf_token=$token&dest=https://${BuildConfig.AUTH_DEST}/callback"
                )
            )
        }
    } catch (e: Exception) {
        actionMutableLiveData.postValue(AuthViewAction.ShowError)
    }
}
