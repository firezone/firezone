/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.PreferenceRepository
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject

internal class ValidateStateUseCase
    @Inject
    constructor(
        private val repository: PreferenceRepository,
    ) {
        operator fun invoke(value: String): Flow<Boolean> = repository.validateState(value)
    }
