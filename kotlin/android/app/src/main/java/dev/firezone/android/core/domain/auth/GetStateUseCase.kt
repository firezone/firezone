/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.domain.auth

import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject

internal class GetStateUseCase
    @Inject
    constructor(
        private val repository: Repository,
    ) {
        operator fun invoke(): Flow<String> = repository.generateNonce("state")
    }
