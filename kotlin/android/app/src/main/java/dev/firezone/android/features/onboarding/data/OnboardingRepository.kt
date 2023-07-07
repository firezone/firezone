package dev.firezone.android.features.onboarding.data

import kotlinx.coroutines.flow.Flow

internal interface OnboardingRepository {
    fun savePortalUrl(value: String): Flow<Unit>
}
