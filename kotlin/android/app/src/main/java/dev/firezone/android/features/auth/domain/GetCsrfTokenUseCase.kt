package dev.firezone.android.features.auth.domain

import dev.firezone.android.features.auth.data.AuthRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class GetCsrfTokenUseCase @Inject constructor(
    private val repository: AuthRepository
) {
    operator fun invoke(): Flow<String> = repository.generateCsrfToken()
}
