package dev.firezone.android.features.onboarding.domain

import dev.firezone.android.features.onboarding.data.OnboardingRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class SavePortalUrlUseCase @Inject constructor(
    private val repository: OnboardingRepository
) {
    operator fun invoke(value: String): Flow<Unit> = repository.savePortalUrl(value)
}
