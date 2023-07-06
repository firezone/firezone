package dev.firezone.android.features.webview.di

import android.content.SharedPreferences
import dev.firezone.android.core.di.IoDispatcher
import dev.firezone.android.features.splash.domain.GetConfigUseCase
import dev.firezone.android.features.webview.data.WebViewRepository
import dev.firezone.android.features.webview.domain.SaveDeepLinkUseCase
import dev.firezone.android.features.webview.domain.WebViewRepositoryImpl
import dev.firezone.android.features.webview.presentation.WebViewViewModel
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineDispatcher

@Module
@InstallIn(SingletonComponent::class)
class WebViewModule {
    @Provides
    internal fun provideViewModel(
        getConfigUseCase: GetConfigUseCase,
        saveDeepLinkUseCase: SaveDeepLinkUseCase,
    ): WebViewViewModel = WebViewViewModel(
        getConfigUseCase,
        saveDeepLinkUseCase
    )

    @Provides
    internal fun provideSaveDeepLinkUseCase(
        repository: WebViewRepository
    ): SaveDeepLinkUseCase = SaveDeepLinkUseCase(repository)

    @Provides
    internal fun provideRepository(
        @IoDispatcher coroutineDispatcher: CoroutineDispatcher,
        sharedPreferences: SharedPreferences
    ): WebViewRepository = WebViewRepositoryImpl(coroutineDispatcher, sharedPreferences)
}
