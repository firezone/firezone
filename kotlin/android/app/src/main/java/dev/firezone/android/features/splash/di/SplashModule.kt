package dev.firezone.android.features.splash.di

import android.content.SharedPreferences
import dev.firezone.android.core.di.IoDispatcher
import dev.firezone.android.features.splash.data.SplashRepository
import dev.firezone.android.features.splash.domain.GetConfigUseCase
import dev.firezone.android.features.splash.domain.SplashRepositoryImpl
import dev.firezone.android.features.splash.presentation.SplashViewModel
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineDispatcher

@Module
@InstallIn(SingletonComponent::class)
class SplashModule {

    @Provides
    internal fun provideViewModel(useCase: GetConfigUseCase): SplashViewModel =
        SplashViewModel(useCase)

    @Provides
    internal fun provideGetConfigUseCase(repository: SplashRepository): GetConfigUseCase =
        GetConfigUseCase(repository)

    @Provides
    internal fun provideRepository(
        @IoDispatcher coroutineDispatcher: CoroutineDispatcher,
        sharedPreferences: SharedPreferences
    ): SplashRepository =
        SplashRepositoryImpl(coroutineDispatcher, sharedPreferences)
}
