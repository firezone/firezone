package dev.firezone.android.features.applink.domain

import dev.firezone.android.features.applink.data.AppLinkRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class ValidateCsrfTokenUseCase @Inject constructor(
    private val repository: AppLinkRepository
) {
    operator fun invoke(value: String): Flow<Boolean> = repository.validateCsrfToken(value)
}
