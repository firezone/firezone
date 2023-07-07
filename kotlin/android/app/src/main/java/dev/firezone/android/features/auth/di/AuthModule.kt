package dev.firezone.android.features.auth.di

import android.content.SharedPreferences
import dev.firezone.android.core.di.IoDispatcher
import dev.firezone.android.features.splash.domain.GetConfigUseCase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.features.auth.data.AuthRepository
import dev.firezone.android.features.auth.domain.AuthRepositoryImpl
import dev.firezone.android.features.auth.domain.GetCsrfTokenUseCase
import dev.firezone.android.features.auth.presentation.AuthViewModel
import kotlinx.coroutines.CoroutineDispatcher

@Module
@InstallIn(SingletonComponent::class)
class AuthModule {
    @Provides
    internal fun provideViewModel(
        getConfigUseCase: GetConfigUseCase,
        getCsrfTokenUseCase: GetCsrfTokenUseCase,
    ): AuthViewModel = AuthViewModel(
        getConfigUseCase,
        getCsrfTokenUseCase,
    )

    @Provides
    internal fun provideRepository(
        @IoDispatcher coroutineDispatcher: CoroutineDispatcher,
        sharedPreferences: SharedPreferences
    ): AuthRepository = AuthRepositoryImpl(coroutineDispatcher, sharedPreferences)
}
