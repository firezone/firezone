/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.core.di

import androidx.test.espresso.idling.CountingIdlingResource
import dagger.Module
import dagger.Provides
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import dev.firezone.android.core.EspressoTrackedDispatcher
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.test.StandardTestDispatcher

@Module
@TestInstallIn(
    components = [SingletonComponent::class],
    replaces = [DispatcherModule::class],
)
object TestDispatcherModule {
    val dispatcher = StandardTestDispatcher()
    val idlingResource = CountingIdlingResource("TestDispatcherModule", true)

    @DefaultDispatcher
    @Provides
    fun providesDefaultDispatcher(): CoroutineDispatcher =
        EspressoTrackedDispatcher(
            idlingResource,
            dispatcher,
        )

    @IoDispatcher
    @Provides
    fun providesIoDispatcher(): CoroutineDispatcher =
        EspressoTrackedDispatcher(
            idlingResource,
            dispatcher,
        )

    @MainDispatcher
    @Provides
    fun providesMainDispatcher(): CoroutineDispatcher =
        EspressoTrackedDispatcher(
            idlingResource,
            dispatcher,
        )

    @MainImmediateDispatcher
    @Provides
    fun providesMainImmediateDispatcher(): CoroutineDispatcher =
        EspressoTrackedDispatcher(
            idlingResource,
            dispatcher,
        )
}
