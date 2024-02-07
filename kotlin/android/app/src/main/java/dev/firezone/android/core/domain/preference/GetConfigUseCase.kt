/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.core.data.model.Config
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject

internal class GetConfigUseCase
    @Inject
    constructor(
        private val repository: PreferenceRepository,
    ) {
        operator fun invoke(): Flow<Config> = repository.getConfig()

        fun sync(): Config = repository.getConfigSync()
        fun clearToken() = repository.clearToken()
        fun getDeviceIdSync(): String? = repository.getDeviceIdSync()
        fun saveDeviceIdSync(deviceId: String) = repository.saveDeviceIdSync(deviceId)
    }
