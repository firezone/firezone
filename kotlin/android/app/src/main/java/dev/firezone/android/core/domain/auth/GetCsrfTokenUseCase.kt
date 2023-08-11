package dev.firezone.android.core.domain.auth

import dev.firezone.android.core.data.AuthRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class GetCsrfTokenUseCase @Inject constructor(
    private val repository: AuthRepository
) {
    operator fun invoke(): Flow<String> = repository.generateCsrfToken()
}
