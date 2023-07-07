package dev.firezone.android.features.splash.presentation

import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.firezone.android.features.splash.domain.GetConfigUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

private const val REQUEST_DELAY = 500L

@HiltViewModel
internal class SplashViewModel @Inject constructor(
    private val useCase: GetConfigUseCase
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<SplashViewAction>()
    val actionLiveData: LiveData<SplashViewAction> = actionMutableLiveData
    fun onGetUserInfo() {
        viewModelScope.launch {
            delay(REQUEST_DELAY)
            useCase.invoke()
                .catch {
                    Log.e("Error", it.message.toString())
                }
                .collect { user ->
                    if (user.portalUrl.isNullOrEmpty()) {
                        actionMutableLiveData.postValue(SplashViewAction.NavigateToOnboardingFragment)
                    } else if (!user.jwt.isNullOrBlank()) {
                        actionMutableLiveData.postValue(SplashViewAction.NavigateToSessionFragment)
                    } else if (user.isConnected) {
                        actionMutableLiveData.postValue(SplashViewAction.NavigateToSessionFragment)
                    } else {
                        actionMutableLiveData.postValue(SplashViewAction.NavigateToSignInFragment)
                    }
                }
        }
    }
}
