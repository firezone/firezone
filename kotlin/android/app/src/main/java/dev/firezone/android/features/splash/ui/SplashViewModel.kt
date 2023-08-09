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

private const val REQUEST_DELAY = 500L

@HiltViewModel
internal class SplashViewModel @Inject constructor(
    private val useCase: GetConfigUseCase,
    private val debugUserUseCase: DebugUserUseCase,
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<ViewAction>()
    val actionLiveData: LiveData<ViewAction> = actionMutableLiveData
    internal fun checkUserState(context: Context) {
        viewModelScope.launch {
            debugUserUseCase()
            delay(REQUEST_DELAY)
            if (!hasVpnPermissions(context)) {
                actionMutableLiveData.postValue(ViewAction.NavigateToVpnPermissionFragment)
            } else {
                useCase.invoke()
                    .catch {
                        Log.e("Error", it.message.toString())
                    }
                    .collect { user ->
                        if (user.portalUrl.isNullOrEmpty()) {
                            actionMutableLiveData.postValue(ViewAction.NavigateToOnboardingFragment)
                        } else if (user.jwt.isNullOrBlank()) {
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
        object NavigateToVpnPermissionFragment : ViewAction()
        object NavigateToOnboardingFragment : ViewAction()
        object NavigateToSignInFragment : ViewAction()
        object NavigateToSessionFragment : ViewAction()
    }
}
