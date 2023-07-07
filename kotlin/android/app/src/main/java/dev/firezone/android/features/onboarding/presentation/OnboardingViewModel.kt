package dev.firezone.android.features.onboarding.presentation

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.firezone.android.features.onboarding.domain.SavePortalUrlUseCase
import dev.firezone.android.features.onboarding.domain.ValidateInputUseCase
import dev.firezone.android.features.splash.domain.GetConfigUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.launch

@HiltViewModel
internal class OnboardingViewModel @Inject constructor(
    private val getConfigUseCase: GetConfigUseCase,
    private val savePortalUrlUseCase: SavePortalUrlUseCase,
    private val validateInputUseCase: ValidateInputUseCase,
) : ViewModel() {

    private val stateMutableLiveData = MutableLiveData<OnboardingViewState>()
    val stateLiveData: LiveData<OnboardingViewState> = stateMutableLiveData

    private val actionMutableLiveData = MutableLiveData<OnboardingViewAction>()
    val actionLiveData: LiveData<OnboardingViewAction> = actionMutableLiveData

    private var input = ""

    fun getPortalUrl() {
        viewModelScope.launch {
            getConfigUseCase.invoke()
                .collect {
                    actionMutableLiveData.postValue(
                        OnboardingViewAction.FillPortalUrl(it.portalUrl.orEmpty())
                    )
                }
        }
    }

    fun onSaveOnboardingCompleted() {
        viewModelScope.launch {
            savePortalUrlUseCase.invoke(input)
                .collect {
                    actionMutableLiveData.postValue(OnboardingViewAction.NavigateToSignInFragment)
                }
        }
    }

    fun onValidateInput(input: String) {
        this.input = input
        val result = validateInputUseCase.invoke(input)

        stateMutableLiveData.postValue(
            OnboardingViewState().copy(
                isButtonEnabled = result.isErrorEnabled.not()
            )
        )
    }
}
