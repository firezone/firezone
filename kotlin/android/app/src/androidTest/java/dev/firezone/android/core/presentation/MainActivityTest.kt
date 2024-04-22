/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.core.presentation

import android.view.View
import android.view.ViewGroup
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.IdlingRegistry
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.test.espresso.matcher.ViewMatchers.withParent
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.R
import dev.firezone.android.core.di.TestDispatcherModule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.hamcrest.Description
import org.hamcrest.Matcher
import org.hamcrest.Matchers.allOf
import org.hamcrest.TypeSafeMatcher
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@LargeTest
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@HiltAndroidTest
class MainActivityTest {
    @get:Rule(order = 0)
    internal var hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    internal var activityScenarioRule = ActivityScenarioRule(MainActivity::class.java)

    @Before
    fun init() {
        IdlingRegistry.getInstance().register(TestDispatcherModule.idlingResource)
        Dispatchers.setMain(TestDispatcherModule.dispatcher)
        hiltRule.inject()
    }

    @After
    fun tearDown() {
        IdlingRegistry.getInstance().unregister(TestDispatcherModule.idlingResource)
        Dispatchers.resetMain()
    }

    @Test
    fun mainActivityTest() =
        runTest {
            advanceUntilIdle()
            onView(
                allOf(
                    withId(R.id.btSettings),
                    withText("Settings"),
                    isDisplayed(),
                ),
            ).perform(click())
            onView(
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
                ),
            ).perform(click())
            onView(
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
                ),
            ).perform(click())
            onView(
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
                ),
            ).perform(click())
            onView(
                allOf(
                    withId(R.id.btSignIn),
                    withText("Sign In"),
                    withParent(withParent(withId(R.id.fragmentContainer))),
                    isDisplayed(),
                ),
            ).check(matches(isDisplayed()))
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
                return parent is ViewGroup && parentMatcher.matches(parent) &&
                    view == parent.getChildAt(position)
            }
        }
    }
}
