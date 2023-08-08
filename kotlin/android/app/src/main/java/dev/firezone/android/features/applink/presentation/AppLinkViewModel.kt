package dev.firezone.android.features.applink.presentation

import android.content.Intent
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.features.applink.domain.SaveJWTUseCase
import dev.firezone.android.features.applink.domain.ValidateCsrfTokenUseCase
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
                "handle_client_auth_callback" -> {
                    intent.data?.getQueryParameter("client_csrf_token")?.let { csrfToken ->
                        if (validateCsrfTokenUseCase(csrfToken).firstOrNull() == true) {
                            System.loadLibrary("connlib")
                            val jwtToken = intent.data?.getQueryParameter("client_auth_token") ?: ""
                            saveJWTUseCase(jwtToken)

                            actionMutableLiveData.postValue(AppLinkViewAction.AuthFlowComplete)
                        }
                    }
                }
                else -> {
                    Log.d("AppLink", "Unknown path segment: ${intent.data?.lastPathSegment}")
                }
            }
        }
    }
}
