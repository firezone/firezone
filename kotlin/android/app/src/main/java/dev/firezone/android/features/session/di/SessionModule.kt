package dev.firezone.android.features.session.di

import dev.firezone.android.features.session.presentation.SessionViewModel
import dev.firezone.android.features.session.backend.SessionManager
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
class SessionModule {

    @Provides
    internal fun provideViewModel(
        sessionManager: SessionManager
    ): SessionViewModel = SessionViewModel(sessionManager)
}
