package dev.firezone.android.features.onboarding.domain

import android.content.SharedPreferences
import dev.firezone.android.features.onboarding.data.OnboardingRepository
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

private const val PORTAL_URL_KEY = "portalUrl"

internal class OnboardingRepositoryImpl @Inject constructor(
    private val coroutineDispatcher: CoroutineDispatcher,
    private val sharedPreferences: SharedPreferences
) : OnboardingRepository {

    override fun savePortalUrl(value: String): Flow<Unit> = flow {
        emit(
            sharedPreferences
                .edit()
                .putString(PORTAL_URL_KEY, value)
                .apply()
        )
    }.flowOn(coroutineDispatcher)
}
