package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.PreferenceRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class GetConfigUseCase @Inject constructor(
    private val repository: PreferenceRepository
) {
    operator fun invoke(): Flow<Config> = repository.getConfig()

    fun sync(): Config = repository.getConfigSync()

}
