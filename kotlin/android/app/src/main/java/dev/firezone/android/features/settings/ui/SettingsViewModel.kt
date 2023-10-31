/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import android.webkit.URLUtil
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.domain.preference.SaveSettingsUseCase
import kotlinx.coroutines.launch
import java.net.URI
import java.net.URISyntaxException
import javax.inject.Inject

@HiltViewModel
internal class SettingsViewModel
    @Inject
    constructor(
        private val getConfigUseCase: GetConfigUseCase,
        private val saveSettingsUseCase: SaveSettingsUseCase,
    ) : ViewModel() {
        private val stateMutableLiveData = MutableLiveData<ViewState>()
        val stateLiveData: LiveData<ViewState> = stateMutableLiveData

        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        private var accountId = ""
        private var authBaseUrl = ""
        private var apiUrl = ""
        private var logFilter = ""

        fun populateFieldsFromConfig() {
            viewModelScope.launch {
                getConfigUseCase().collect {
                    actionMutableLiveData.postValue(
                        ViewAction.FillSettings(
                            it.accountId.orEmpty(),
                            it.authBaseUrl.orEmpty(),
                            it.apiUrl.orEmpty(),
                            it.logFilter.orEmpty(),
                        ),
                    )
                }
            }
        }

        fun onSaveSettingsCompleted() {
            viewModelScope.launch {
                saveSettingsUseCase(accountId, authBaseUrl, apiUrl, logFilter).collect {
                    actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
                }
            }
        }

        fun onCancel() {
            actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
        }

        fun onValidateAccountId(accountId: String) {
            this.accountId = accountId
            stateMutableLiveData.postValue(
                ViewState().copy(
                    isSaveButtonEnabled = areFieldsValid(),
                ),
            )
        }

        fun onValidateAuthBaseUrl(authBaseUrl: String) {
            this.authBaseUrl = authBaseUrl
            stateMutableLiveData.postValue(
                ViewState().copy(
                    isSaveButtonEnabled = areFieldsValid(),
                ),
            )
        }

        fun onValidateApiUrl(apiUrl: String) {
            this.apiUrl = apiUrl
            stateMutableLiveData.postValue(
                ViewState().copy(
                    isSaveButtonEnabled = areFieldsValid(),
                ),
            )
        }

        fun onValidateLogFilter(logFilter: String) {
            this.logFilter = logFilter
            stateMutableLiveData.postValue(
                ViewState().copy(
                    isSaveButtonEnabled = areFieldsValid(),
                ),
            )
        }

        internal sealed class ViewAction {
            object NavigateToSignIn : ViewAction()

            data class FillSettings(
                val accountId: String,
                val authBaseUrl: String,
                val apiUrl: String,
                val logFilter: String,
            ) : ViewAction()
        }

        private fun areFieldsValid(): Boolean {
            // This comes from the backend account slug validator at elixir/apps/domain/lib/domain/accounts/account/changeset.ex
            val accountIdRegex = Regex("^[a-z0-9_]{3,100}\$")
            return accountIdRegex.matches(accountId) &&
                URLUtil.isValidUrl(authBaseUrl) &&
                isUriValid(apiUrl) &&
                logFilter.isNotBlank()
        }

        private fun isUriValid(uri: String): Boolean {
            return try {
                URI(uri)
                true
            } catch (e: URISyntaxException) {
                false
            }
        }

        internal data class ViewState(
            val isSaveButtonEnabled: Boolean = false,
        )
    }
