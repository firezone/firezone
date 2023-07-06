package dev.firezone.android.features.onboarding.di

import android.content.SharedPreferences
import dev.firezone.android.core.di.IoDispatcher
import dev.firezone.android.features.onboarding.data.OnboardingRepository
import dev.firezone.android.features.onboarding.domain.OnboardingRepositoryImpl
import dev.firezone.android.features.onboarding.domain.SavePortalUrlUseCase
import dev.firezone.android.features.onboarding.domain.ValidateInputUseCase
import dev.firezone.android.features.onboarding.presentation.OnboardingViewModel
import dev.firezone.android.features.splash.domain.GetConfigUseCase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineDispatcher

@Module
@InstallIn(SingletonComponent::class)
class OnboardingModule {
    @Provides
    internal fun provideViewModel(
        getConfigUseCase: GetConfigUseCase,
        savePortalUrlUseCase: SavePortalUrlUseCase,
        validateInputUseCase: ValidateInputUseCase
    ): OnboardingViewModel = OnboardingViewModel(
        getConfigUseCase,
        savePortalUrlUseCase,
        validateInputUseCase
    )

    @Provides
    internal fun provideSavePortalUrlUseCase(
        repository: OnboardingRepository
    ): SavePortalUrlUseCase = SavePortalUrlUseCase(repository)

    @Provides
    internal fun provideValidateInputUseCase(): ValidateInputUseCase = ValidateInputUseCase()

    @Provides
    internal fun provideRepository(
        @IoDispatcher coroutineDispatcher: CoroutineDispatcher,
        sharedPreferences: SharedPreferences
    ): OnboardingRepository = OnboardingRepositoryImpl(coroutineDispatcher, sharedPreferences)
}
