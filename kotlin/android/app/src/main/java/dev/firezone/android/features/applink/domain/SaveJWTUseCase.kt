package dev.firezone.android.features.applink.domain

import dev.firezone.android.features.applink.data.AppLinkRepository
import dev.firezone.android.features.auth.data.AuthRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class SaveJWTUseCase @Inject constructor(
    private val repository: AppLinkRepository
) {
    operator fun invoke(value: String): Flow<Unit> = repository.saveJWT(value)
}
