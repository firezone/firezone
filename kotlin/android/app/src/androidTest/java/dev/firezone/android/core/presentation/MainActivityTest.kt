// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.presentation

import android.content.Context
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.base.DefaultFailureHandler
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.isRoot
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry.getInstrumentation
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiSelector
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.R
import dev.firezone.android.core.waitForView
import org.hamcrest.Description
import org.hamcrest.Matcher
import org.hamcrest.Matchers.allOf
import org.hamcrest.TypeSafeMatcher
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale

@LargeTest
@RunWith(AndroidJUnit4::class)
@HiltAndroidTest
class MainActivityTest {
    // Running count of the number of Android Not Responding dialogues to prevent endless dismissal.
    private var anrCount = 0

    // `RootViewWithoutFocusException` class is private, need to match the message (instead of using type matching).
    private val rootViewWithoutFocusExceptionMsg =
        java.lang.String.format(
            Locale.ROOT,
            "Waited for the root of the view hierarchy to have " +
                "window focus and not request layout for 10 seconds. If you specified a non " +
                "default root matcher, it may be picking a root that never takes focus. " +
                "Root:",
        )

    @get:Rule(order = 0)
    internal var hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    internal var activityScenarioRule = ActivityScenarioRule(MainActivity::class.java)

    @Before
    fun init() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        Espresso.setFailureHandler { error, viewMatcher ->
            if (error.message!!.contains(rootViewWithoutFocusExceptionMsg) && anrCount < 3) {
                anrCount++
                handleAnrDialogue()
            } else { // chain all failures down to the default espresso handler
                DefaultFailureHandler(context).handle(error, viewMatcher)
            }
        }
        hiltRule.inject()
    }

    @Test
    fun mainActivityTest() {
        val btSettingsMatchers =
            allOf(
                withId(R.id.btSettings),
                withText("Settings"),
                isDisplayed(),
            )
        val btLogsMatchers =
            allOf(
                withContentDescription("Logs"),
                childAtPosition(
                    childAtPosition(
                        withId(R.id.tabLayout),
                        0,
                    ),
                    1,
                ),
                isDisplayed(),
            )
        val btAdvancedMatchers =
            allOf(
                withContentDescription("Advanced"),
                childAtPosition(
                    childAtPosition(
                        withId(R.id.tabLayout),
                        0,
                    ),
                    0,
                ),
                isDisplayed(),
            )
        val btSaveSettingsMatchers =
            allOf(
                withId(R.id.btSaveSettings),
                withText("Save"),
                childAtPosition(
                    childAtPosition(
                        withId(android.R.id.content),
                        0,
                    ),
                    2,
                ),
                isDisplayed(),
            )
        onView(isRoot()).perform(waitForView(btSettingsMatchers))
        onView(btSettingsMatchers).perform(click())

        onView(isRoot()).perform(waitForView(btLogsMatchers))
        onView(btLogsMatchers).perform(click())

        onView(isRoot()).perform(waitForView(btAdvancedMatchers))
        onView(btAdvancedMatchers).perform(click())

        onView(isRoot()).perform(waitForView(btSaveSettingsMatchers))
        onView(btSaveSettingsMatchers).perform(click())
    }

    private fun handleAnrDialogue() {
        val device = UiDevice.getInstance(getInstrumentation())
        // If running the device in English Locale
        val waitButton = device.findObject(UiSelector().textContains("wait"))
        if (waitButton.exists()) waitButton.click()
    }

    private fun childAtPosition(
        parentMatcher: Matcher<View>,
        position: Int,
    ): Matcher<View> {
        return object : TypeSafeMatcher<View>() {
            override fun describeTo(description: Description) {
                description.appendText("Child at position $position in parent ")
                parentMatcher.describeTo(description)
            }

            public override fun matchesSafely(view: View): Boolean {
                val parent = view.parent
                return parent is ViewGroup &&
                    parentMatcher.matches(parent) &&
                    view == parent.getChildAt(position)
            }
        }
    }
}
