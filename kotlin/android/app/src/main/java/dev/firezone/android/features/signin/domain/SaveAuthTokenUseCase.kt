package dev.firezone.android.features.signin.domain

import dev.firezone.android.features.signin.data.SignInRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class SaveAuthTokenUseCase @Inject constructor(
    private val repository: SignInRepository
) {
    operator fun invoke(): Flow<Unit> = repository.saveAuthToken()
}
