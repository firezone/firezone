package dev.firezone.android.features.splash.ui

import android.content.Context
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.DebugUserUseCase
import javax.inject.Inject
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

private const val REQUEST_DELAY = 1000L

@HiltViewModel
internal class SplashViewModel @Inject constructor(
    private val useCase: GetConfigUseCase,
    private val debugUserUseCase: DebugUserUseCase,
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<ViewAction>()
    val actionLiveData: LiveData<ViewAction> = actionMutableLiveData
    internal fun checkUserState(context: Context) {
        viewModelScope.launch {
            //debugUserUseCase() // sets dummy team-id and token

            delay(REQUEST_DELAY)
            if (!hasVpnPermissions(context)) {
                actionMutableLiveData.postValue(ViewAction.NavigateToVpnPermission)
            } else {
                useCase.invoke()
                    .catch {
                        Log.e("Error", it.message.toString())
                    }
                    .collect { user ->
                        if (user.accountId.isNullOrEmpty()) {
                            actionMutableLiveData.postValue(ViewAction.NavigateToOnboardingFragment)
                        } else if (user.token.isNullOrBlank()) {
                            actionMutableLiveData.postValue(ViewAction.NavigateToSignInFragment)
                        } else {
                            actionMutableLiveData.postValue(ViewAction.NavigateToSessionFragment)
                        }
                    }
            }
        }
    }

    private fun hasVpnPermissions(context: Context): Boolean {
        return android.net.VpnService.prepare(context) == null
    }

    internal sealed class ViewAction {
        object NavigateToVpnPermission : ViewAction()
        object NavigateToOnboardingFragment : ViewAction()
        object NavigateToSignInFragment : ViewAction()
        object NavigateToSessionFragment : ViewAction()
    }
}
