package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.PreferenceRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class SavePortalUrlUseCase @Inject constructor(
    private val repository: PreferenceRepository
) {
    operator fun invoke(portalUrl: String): Flow<Unit> = repository.savePortalUrl(portalUrl)
}
