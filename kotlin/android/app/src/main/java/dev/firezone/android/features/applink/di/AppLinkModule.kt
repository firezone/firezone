package dev.firezone.android.features.applink.di

/*
import android.content.SharedPreferences
import dev.firezone.android.core.di.IoDispatcher
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.features.applink.data.AppLinkRepository
import dev.firezone.android.features.applink.domain.AppLinkRepositoryImpl
import dev.firezone.android.features.applink.domain.SaveJWTUseCase
import dev.firezone.android.core.domain.preference.ValidateCsrfTokenUseCase
import dev.firezone.android.features.applink.ui.AppLinkViewModel
import kotlinx.coroutines.CoroutineDispatcher

@Module
@InstallIn(SingletonComponent::class)
class AppLinkModule {
    @Provides
    internal fun provideViewModel(
        validateCsrfTokenUseCase: ValidateCsrfTokenUseCase,
        saveJWTUseCase: SaveJWTUseCase,
    ): AppLinkViewModel = AppLinkViewModel(
        validateCsrfTokenUseCase,
        saveJWTUseCase
    )

    @Provides
    internal fun provideRepository(
        @IoDispatcher coroutineDispatcher: CoroutineDispatcher,
        sharedPreferences: SharedPreferences
    ): AppLinkRepository = AppLinkRepositoryImpl(coroutineDispatcher, sharedPreferences)
}
*/
