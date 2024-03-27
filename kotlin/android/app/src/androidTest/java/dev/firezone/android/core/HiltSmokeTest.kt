package dev.firezone.android.core

import android.app.Application
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dagger.hilt.android.testing.HiltTestApplication
import org.junit.Rule
import org.junit.Test
import javax.inject.Inject

@HiltAndroidTest
class HiltSmokeTest {

    @get:Rule
    var hiltRule = HiltAndroidRule(this)

    @Inject
    lateinit var application: Application

    @Test
    fun testApplicationShouldInjectWithoutErrors() {
        hiltRule.inject()
        assert(application is HiltTestApplication)
    }
}