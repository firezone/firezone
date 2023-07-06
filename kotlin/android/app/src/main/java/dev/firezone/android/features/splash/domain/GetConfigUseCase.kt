package dev.firezone.android.features.splash.domain

import dev.firezone.android.core.data.Config
import dev.firezone.android.features.splash.data.SplashRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow

internal class GetConfigUseCase @Inject constructor(
    private val repository: SplashRepository
) {
    operator fun invoke(): Flow<Config> = repository.getConfig()
}
