package dev.firezone.android.features.signin.di

import android.content.SharedPreferences
import dev.firezone.android.core.di.IoDispatcher
import dev.firezone.android.features.signin.data.SignInRepository
import dev.firezone.android.features.signin.domain.SaveAuthTokenUseCase
import dev.firezone.android.features.signin.domain.SignInRepositoryImpl
import dev.firezone.android.features.signin.presentation.SignInViewModel
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineDispatcher

@Module
@InstallIn(SingletonComponent::class)
class SignInModule {
    @Provides
    internal fun provideViewModel(
        saveAuthTokenUseCase: SaveAuthTokenUseCase
    ): SignInViewModel = SignInViewModel(
        saveAuthTokenUseCase
    )

    @Provides
    internal fun provideSaveWireGuardKeyUseCase(
        repository: SignInRepository
    ): SaveAuthTokenUseCase = SaveAuthTokenUseCase(repository)

    @Provides
    internal fun provideRepository(
        @IoDispatcher coroutineDispatcher: CoroutineDispatcher,
        sharedPreferences: SharedPreferences
    ): SignInRepository = SignInRepositoryImpl(coroutineDispatcher, sharedPreferences)
}
