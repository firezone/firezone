/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.domain.preference.SaveAccountIdUseCase
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
internal class SettingsViewModel
    @Inject
    constructor(
        private val getConfigUseCase: GetConfigUseCase,
        private val saveAccountIdUseCase: SaveAccountIdUseCase,
    ) : ViewModel() {
        private val stateMutableLiveData = MutableLiveData<ViewState>()
        val stateLiveData: LiveData<ViewState> = stateMutableLiveData

        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        private var input = ""

        fun getAccountId() {
            viewModelScope.launch {
                getConfigUseCase().collect {
                    actionMutableLiveData.postValue(
                        ViewAction.FillAccountId(it.accountId.orEmpty()),
                    )
                }
            }
        }

        fun onSaveSettingsCompleted() {
            viewModelScope.launch {
                saveAccountIdUseCase(input).collect {
                    actionMutableLiveData.postValue(ViewAction.NavigateToSignInFragment)
                }
            }
        }

        fun onValidateInput(input: String) {
            this.input = input
            stateMutableLiveData.postValue(
                ViewState().copy(
                    isButtonEnabled = input.isEmpty().not(),
                ),
            )
        }

        companion object {
            val AUTH_URL = "${BuildConfig.AUTH_SCHEME}://${BuildConfig.AUTH_HOST}:${BuildConfig.AUTH_PORT}/"
        }

        internal sealed class ViewAction {
            object NavigateToSignInFragment : ViewAction()

            data class FillAccountId(val value: String) : ViewAction()
        }

        internal data class ViewState(
            val isButtonEnabled: Boolean = false,
        )
    }
