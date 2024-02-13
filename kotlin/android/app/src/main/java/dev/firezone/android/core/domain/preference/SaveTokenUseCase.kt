/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject

internal class SaveTokenUseCase
    @Inject
    constructor(
        private val repository: Repository,
    ) {
        operator fun invoke(token: String): Flow<Unit> = repository.saveToken(token)
    }
