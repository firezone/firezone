package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.PreferenceRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class SaveAccountIdUseCase @Inject constructor(
    private val repository: PreferenceRepository
) {
    operator fun invoke(accountId: String): Flow<Unit> = repository.saveAccountId(accountId)
}
