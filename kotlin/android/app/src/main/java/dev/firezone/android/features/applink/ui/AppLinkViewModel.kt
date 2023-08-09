package dev.firezone.android.features.applink.ui

import android.content.Intent
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.SaveJWTUseCase
import dev.firezone.android.core.domain.preference.ValidateCsrfTokenUseCase
import javax.inject.Inject
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch

@HiltViewModel
internal class AppLinkViewModel @Inject constructor(
    private val validateCsrfTokenUseCase: ValidateCsrfTokenUseCase,
    private val saveJWTUseCase: SaveJWTUseCase,
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<AppLinkViewAction>()
    val actionLiveData: LiveData<AppLinkViewAction> = actionMutableLiveData

    fun parseAppLink(intent: Intent) {
        viewModelScope.launch {
            when (intent.data?.lastPathSegment) {
                PATH_CALLBACK -> {
                    intent.data?.getQueryParameter(QUERY_CLIENT_CSRF_TOKEN)?.let { csrfToken ->
                        if (validateCsrfTokenUseCase(csrfToken).firstOrNull() == true) {
                            val jwtToken = intent.data?.getQueryParameter(QUERY_CLIENT_AUTH_TOKEN) ?: ""
                            saveJWTUseCase(jwtToken)

                            actionMutableLiveData.postValue(AppLinkViewAction.AuthFlowComplete)
                        }
                    }
                }
                else -> {}
            }
        }
    }

    companion object {
        private const val PATH_CALLBACK = "callback"
        private const val QUERY_CLIENT_CSRF_TOKEN = "client_csrf_token"
        private const val QUERY_CLIENT_AUTH_TOKEN = "client_auth_token"
    }
}
