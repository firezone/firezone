package dev.firezone.android.core.domain.preference

import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.PreferenceRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flowOf

internal class DebugUserUseCase @Inject constructor(
    private val repository: PreferenceRepository
) {
    suspend operator fun invoke(): Flow<Unit> {
        repository.saveAccountId("firezone").collect()
        return flowOf ()
    }
}
