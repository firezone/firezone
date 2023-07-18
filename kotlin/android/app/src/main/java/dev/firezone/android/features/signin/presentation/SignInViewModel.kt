package dev.firezone.android.features.signin.presentation

import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.firezone.android.features.signin.domain.SaveAuthTokenUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

@HiltViewModel
internal class SignInViewModel @Inject constructor(
    private val saveAuthTokenUseCase: SaveAuthTokenUseCase,
) : ViewModel() {

    private val actionMutableLiveData = MutableLiveData<SignInViewAction>()
    val actionLiveData: LiveData<SignInViewAction> = actionMutableLiveData

    fun onSaveAuthToken() {
        viewModelScope.launch {
            saveAuthTokenUseCase.invoke()
                .catch {
                    Log.e("Error", it.message.toString())
                }
                .collect {
                    actionMutableLiveData.postValue(SignInViewAction.NavigateToAuthActivity)
                }
        }
    }
}
