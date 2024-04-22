/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.core

import androidx.test.espresso.idling.CountingIdlingResource
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Delay
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.test.TestDispatcher
import kotlin.coroutines.CoroutineContext

@OptIn(InternalCoroutinesApi::class)
class EspressoTrackedDispatcher(
    private val counter: CountingIdlingResource,
    private val wrapped: TestDispatcher,
) : CoroutineDispatcher(), Delay {
    private fun wrapBlock(block: Runnable) =
        Runnable {
            try {
                block.run()
            } finally {
                counter.decrement()
                counter.dumpStateToLogs()
            }
        }

    override fun dispatch(
        context: CoroutineContext,
        block: Runnable,
    ) {
        counter.increment()
        counter.dumpStateToLogs()
        wrapped.dispatch(wrapped, wrapBlock(block))
    }

    override fun scheduleResumeAfterDelay(
        timeMillis: Long,
        continuation: CancellableContinuation<Unit>,
    ) {
        wrapped.scheduleResumeAfterDelay(
            timeMillis,
            object : CancellableContinuation<Unit> by continuation {
                override fun cancel(cause: Throwable?) = continuation.cancel(cause).also { counter.decrement() }

                @InternalCoroutinesApi
                override fun completeResume(token: Any) = continuation.completeResume(token).also { counter.decrement() }
            },
        )
    }
}
