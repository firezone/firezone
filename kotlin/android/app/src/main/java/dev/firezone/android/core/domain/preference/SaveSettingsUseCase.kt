/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.PreferenceRepository
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject

internal class SaveSettingsUseCase
    @Inject
    constructor(
        private val repository: PreferenceRepository,
    ) {
        operator fun invoke(
            authBaseUrl: String,
            apiUrl: String,
            logFilter: String,
        ): Flow<Unit> = repository.saveSettings(authBaseUrl, apiUrl, logFilter)
    }
