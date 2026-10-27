// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.os.Looper
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.data.model.Portal
import dev.firezone.android.core.data.model.SignInSettings
import dev.firezone.android.features.session.ui.SessionViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class SettingsViewModelTest {
    private lateinit var sharedPreferences: SharedPreferences
    private lateinit var repository: Repository
    private lateinit var tokenStore: TokenStore
    private lateinit var viewModel: SettingsViewModel

    @Before
    fun setUp() {
        sharedPreferences =
            RuntimeEnvironment
                .getApplication()
                .getSharedPreferences("settings-view-model-test", Context.MODE_PRIVATE)
        sharedPreferences.edit().clear().commit()
        repository = Repository(RuntimeEnvironment.getApplication(), Dispatchers.Unconfined, sharedPreferences)
        tokenStore = TokenStore(sharedPreferences)
        viewModel = SettingsViewModel(repository)
    }

    @Test
    fun `a reset clears favorites and keeps managed values`() =
        runBlocking {
            repository.addFavoriteResource(FAVORITE_ID)
            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString("authUrl", "https://managed.example.com")
                    },
                ).first()

            viewModel.resetSettingsToDefaults()
            settle()

            assertTrue(
                repository.favorites.value.inner
                    .isEmpty(),
            )
            assertEquals("https://managed.example.com", viewModel.config.authUrl)
        }

    @Test
    fun `saved US URLs show the US portal`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")

        populateFields()

        assertEquals(Portal.CLOUD_US, viewModel.portal)
    }

    @Test
    fun `saved self-hosted URLs show custom and keep the URLs`() {
        saveUrls("https://firezone.example.com", "wss://api.example.com")

        populateFields()

        assertEquals(Portal.CUSTOM, viewModel.portal)
        assertEquals("https://firezone.example.com", viewModel.config.authUrl)
        assertEquals("wss://api.example.com", viewModel.config.apiUrl)
    }

    @Test
    fun `picking the EU portal saves the EU URLs`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        populateFields()

        viewModel.onPortalChanged(Portal.CLOUD_EU)
        settle()

        assertEquals("https://eu.app.firezone.dev", repository.getConfigSync().authUrl)
        assertEquals("wss://eu.api.firezone.dev", repository.getConfigSync().apiUrl)
    }

    @Test
    fun `one managed URL shows custom`() =
        runBlocking {
            saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
            repository
                .saveManagedConfiguration(
                    Bundle().apply {
                        putString("apiUrl", "wss://api.firezone.dev")
                    },
                ).first()

            populateFields()

            assertEquals(Portal.CUSTOM, viewModel.portal)
        }

    @Test
    fun `saved URLs with a trailing slash still show their portal`() {
        saveUrls("https://eu.app.firezone.dev/", "wss://eu.api.firezone.dev/")

        populateFields()

        assertEquals(Portal.CLOUD_EU, viewModel.portal)
    }

    @Test
    fun `picking custom keeps the URLs for editing`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        populateFields()

        viewModel.onPortalChanged(Portal.CUSTOM)
        viewModel.onAuthUrlChanged("https://firezone.example.com")
        viewModel.onApiUrlChanged("wss://api.firezone.example.com")
        settle()

        assertEquals(Portal.CUSTOM, viewModel.portal)
        assertEquals("https://firezone.example.com", repository.getConfigSync().authUrl)
        assertEquals("wss://api.firezone.example.com", repository.getConfigSync().apiUrl)
    }

    @Test
    fun `managed EU URLs show the EU portal`() =
        runBlocking {
            saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
            manageUrls("https://eu.app.firezone.dev/", "wss://eu.api.firezone.dev")

            populateFields()

            assertEquals(Portal.CLOUD_EU, viewModel.portal)
        }

    @Test
    fun `managed self-hosted URLs show custom`() =
        runBlocking {
            manageUrls("https://firezone.example.com", "wss://api.firezone.example.com")

            populateFields()

            assertEquals(Portal.CUSTOM, viewModel.portal)
            assertEquals("https://firezone.example.com", viewModel.config.authUrl)
        }

    @Test
    fun `a confirmed account slug persists immediately`() {
        populateFields()

        viewModel.onAccountSlugChanged("example-corp")
        settle()

        assertEquals("example-corp", repository.getConfigSync().accountSlug)
    }

    @Test
    fun `the settings a session signed in with are remembered until sign-out`() {
        val signedInWith = SignInSettings("example-corp", "https://app.firezone.dev", "wss://api.firezone.dev")

        assertNull(SettingsViewModel(repository).signedInWith)

        repository.saveActiveSignInSettingsSync(signedInWith)
        tokenStore.save("token")
        reopen()

        viewModel.onPortalChanged(Portal.CLOUD_EU)
        settle()

        assertEquals("wss://eu.api.firezone.dev", repository.getConfigSync().apiUrl)
        assertEquals(signedInWith, repository.getActiveSignInSettingsSync())
        assertEquals(signedInWith, viewModel.signedInWith)

        SessionViewModel(repository, tokenStore).clearToken()
        assertNull(tokenStore.get())
        assertNull(SettingsViewModel(repository).signedInWith)
    }

    @Test
    fun `a toggled switch persists immediately`() {
        populateFields()

        viewModel.onConnectOnStartChanged(true)
        settle()

        assertTrue(repository.getConfigSync().connectOnStart)
    }

    @Test
    fun `a confirmed log filter persists immediately`() {
        populateFields()

        viewModel.onLogFilterChanged("debug")
        settle()

        assertEquals("debug", repository.getConfigSync().logFilter)
    }

    @Test
    fun `switching back to custom brings back the last saved custom URLs`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        populateFields()
        viewModel.onPortalChanged(Portal.CUSTOM)
        viewModel.onAuthUrlChanged("https://firezone.example.com")
        viewModel.onApiUrlChanged("wss://api.firezone.example.com")
        settle()

        reopen()
        viewModel.onPortalChanged(Portal.CLOUD_EU)
        settle()

        reopen()
        viewModel.onPortalChanged(Portal.CUSTOM)

        assertEquals("https://firezone.example.com", viewModel.config.authUrl)
        assertEquals("wss://api.firezone.example.com", viewModel.config.apiUrl)
    }

    @Test
    fun `switching away from existing custom URLs remembers them without editing`() {
        saveUrls("https://firezone.example.com", "wss://api.firezone.example.com")
        populateFields()

        viewModel.onPortalChanged(Portal.CLOUD_EU)
        settle()
        reopen()
        viewModel.onPortalChanged(Portal.CUSTOM)

        assertEquals("https://firezone.example.com", viewModel.config.authUrl)
        assertEquals("wss://api.firezone.example.com", viewModel.config.apiUrl)
    }

    @Test
    fun `switching to custom without saved custom URLs keeps the current ones`() {
        saveUrls("https://eu.app.firezone.dev", "wss://eu.api.firezone.dev")
        populateFields()

        viewModel.onPortalChanged(Portal.CUSTOM)

        assertEquals("https://eu.app.firezone.dev", viewModel.config.authUrl)
        assertEquals("wss://eu.api.firezone.dev", viewModel.config.apiUrl)
    }

    @Test
    fun `saving a cloud portal does not remember its URLs as custom`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        repository.saveLastCustomUrlsSync("https://firezone.example.com", "wss://api.firezone.example.com")
        populateFields()

        viewModel.onPortalChanged(Portal.CLOUD_US)
        settle()

        assertEquals(
            "https://firezone.example.com" to "wss://api.firezone.example.com",
            repository.getLastCustomUrlsSync(),
        )
    }

    @Test
    fun `remembered custom URLs do not change the portal shown`() {
        saveUrls("https://app.firezone.dev", "wss://api.firezone.dev")
        repository.saveLastCustomUrlsSync("https://firezone.example.com", "wss://api.firezone.example.com")

        populateFields()

        assertEquals(Portal.CLOUD_US, viewModel.portal)
        assertEquals("https://app.firezone.dev", viewModel.config.authUrl)
    }

    @Test
    fun `managed custom URLs are not remembered`() =
        runBlocking {
            manageUrls("https://firezone.example.com", "wss://api.firezone.example.com")
            populateFields()

            viewModel.onConnectOnStartChanged(true)
            settle()

            assertEquals(null, repository.getLastCustomUrlsSync())
        }

    private fun settle() {
        shadowOf(Looper.getMainLooper()).idle()
    }

    // What opening the settings screen again starts from.
    private fun reopen() {
        viewModel = SettingsViewModel(repository)
        populateFields()
    }

    private suspend fun manageUrls(
        authUrl: String,
        apiUrl: String,
    ) {
        repository
            .saveManagedConfiguration(
                Bundle().apply {
                    putString("authUrl", authUrl)
                    putString("apiUrl", apiUrl)
                },
            ).first()
    }

    private fun saveUrls(
        authUrl: String,
        apiUrl: String,
    ) {
        sharedPreferences
            .edit()
            .putString("authUrl", authUrl)
            .putString("apiUrl", apiUrl)
            .commit()
    }

    private fun populateFields() {
        viewModel.populateFieldsFromConfig()
        shadowOf(Looper.getMainLooper()).idle()
    }

    private companion object {
        const val FAVORITE_ID = "favorite-resource"
    }
}
