// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.view.View
import androidx.test.espresso.PerformException
import androidx.test.espresso.UiController
import androidx.test.espresso.ViewAction
import androidx.test.espresso.matcher.ViewMatchers.isRoot
import androidx.test.espresso.util.HumanReadables
import androidx.test.espresso.util.TreeIterables
import org.hamcrest.Matcher
import org.hamcrest.StringDescription
import java.util.concurrent.TimeoutException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

fun waitForView(
    vararg matchers: Matcher<View>,
    timeout: Duration = 5.seconds,
): ViewAction {
    return object : ViewAction {
        private val timeoutMillis = timeout.inWholeMilliseconds

        override fun getConstraints() = isRoot()

        override fun getDescription(): String {
            val subDescription = StringDescription()
            matchers.forEach { it.describeTo(subDescription) }
            return "Wait for a view matching one of: $subDescription; with a timeout of $timeout."
        }

        override fun perform(
            uiController: UiController,
            rootView: View,
        ) {
            uiController.loopMainThreadUntilIdle()
            val startTime = System.currentTimeMillis()
            val endTime = startTime + timeoutMillis

            do {
                for (child in TreeIterables.breadthFirstViewTraversal(rootView)) {
                    if (matchers.any { matcher -> matcher.matches(child) }) {
                        return
                    }
                }
                uiController.loopMainThreadForAtLeast(100)
            } while (System.currentTimeMillis() < endTime)

            throw PerformException
                .Builder()
                .withCause(TimeoutException())
                .withActionDescription(this.description)
                .withViewDescription(HumanReadables.describe(rootView))
                .build()
        }
    }
}
