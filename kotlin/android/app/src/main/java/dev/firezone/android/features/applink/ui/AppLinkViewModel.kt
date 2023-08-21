package dev.firezone.android.features.applink.ui

import android.content.Intent
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.SaveTokenUseCase
import dev.firezone.android.core.domain.preference.ValidateCsrfTokenUseCase
import javax.inject.Inject
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch

@HiltViewModel
internal class AppLinkViewModel @Inject constructor(
    private val validateCsrfTokenUseCase: ValidateCsrfTokenUseCase,
    private val saveTokenUseCase: SaveTokenUseCase,
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<ViewAction>()
    val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

    fun parseAppLink(intent: Intent) {
        viewModelScope.launch {
            when (intent.data?.lastPathSegment) {
                PATH_CALLBACK -> {
                    intent.data?.getQueryParameter(QUERY_CLIENT_CSRF_TOKEN)?.let { csrfToken ->
                        if (validateCsrfTokenUseCase(csrfToken).firstOrNull() == true) {
                            Log.d("AppLink", "Valid CSRF token. Continuing to save token...")
                            val token = intent.data?.getQueryParameter(QUERY_CLIENT_AUTH_TOKEN) ?: ""
                            saveTokenUseCase(token)

                            actionMutableLiveData.postValue(ViewAction.AuthFlowComplete)
                        }
                    }
                }
                else -> {
                    Log.d("AppLink", "Unknown path segment: ${intent.data?.lastPathSegment}")
                }
            }
        }
    }

    companion object {
        private const val PATH_CALLBACK = "handle_client_auth_callback"
        private const val QUERY_CLIENT_CSRF_TOKEN = "client_csrf_token"
        private const val QUERY_CLIENT_AUTH_TOKEN = "client_auth_token"
        private const val QUERY_ACTOR_NAME = "actor_name"
        private const val QUERY_IDENTITY_PROVIDER_IDENTIFIER = "identity_provider_identifier"
    }

    internal sealed class ViewAction {

        object AuthFlowComplete : ViewAction()

        object ShowError : ViewAction()
    }
}
