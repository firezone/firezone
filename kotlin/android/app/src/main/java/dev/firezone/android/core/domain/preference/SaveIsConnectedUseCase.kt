package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.PreferenceRepository
import javax.inject.Inject

internal class SaveIsConnectedUseCase @Inject constructor(
    private val repository: PreferenceRepository
) {
    operator fun invoke(isConnected: Boolean) {
        repository.saveIsConnectedSync(isConnected)
    }

    fun sync(isConnected: Boolean) {
        repository.saveIsConnectedSync(isConnected)
    }
}
