/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.signin.ui

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import javax.inject.Inject

@HiltViewModel
internal class SignInViewModel
    @Inject
    constructor(
        private val useCase: GetConfigUseCase,
    ) : ViewModel() {
        private val actionMutableLiveData = MutableLiveData<SignInViewAction>()
        val actionLiveData: LiveData<SignInViewAction> = actionMutableLiveData

        internal sealed class SignInViewAction {
            object NavigateToAuthActivity : SignInViewAction()
        }
    }
