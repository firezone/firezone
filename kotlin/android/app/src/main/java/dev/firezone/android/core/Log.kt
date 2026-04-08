// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import io.sentry.Sentry
import io.sentry.SentryAttribute
import io.sentry.SentryAttributes
import io.sentry.SentryLevel
import io.sentry.SentryLogLevel
import io.sentry.logger.SentryLogParameters
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Log wrapper that writes to both Android logcat and (when streaming is active)
 * Sentry structured logs.
 */
object Log {
    private val streamingActive = AtomicBoolean(false)

    @Volatile
    private var attributes: Map<String, String> = mapOf("process" to "app")

    private val attributesLock = Any()

    val isStreamingActive: Boolean
        get() = streamingActive.get()

    fun setStreamingActive(active: Boolean) {
        val changed = streamingActive.getAndSet(active) != active
        if (changed) {
            d("Log", "Log streaming ${if (active) "enabled" else "disabled"}")
        }
    }

    fun setUser(
        firezoneId: String,
        accountSlug: String,
    ) {
        synchronized(attributesLock) {
            attributes = attributes +
                mapOf(
                    "user.id" to firezoneId,
                    "user.account_slug" to accountSlug,
                )
        }
    }

    fun clearUser() {
        synchronized(attributesLock) {
            attributes = attributes - "user.id" - "user.account_slug"
        }
    }

    fun setEnvironment(environment: String) {
        synchronized(attributesLock) {
            attributes = attributes + ("environment" to environment)
        }
    }

    fun v(
        tag: String,
        msg: String,
    ): Int =
        android.util.Log.v(tag, msg).also {
            sentryLog(SentryLogLevel.TRACE, tag, msg)
        }

    fun d(
        tag: String,
        msg: String,
    ): Int =
        android.util.Log.d(tag, msg).also {
            sentryLog(SentryLogLevel.DEBUG, tag, msg)
        }

    fun d(
        tag: String,
        msg: String,
        tr: Throwable,
    ): Int =
        android.util.Log.d(tag, msg, tr).also {
            sentryLog(SentryLogLevel.DEBUG, tag, "$msg\n${android.util.Log.getStackTraceString(tr)}")
        }

    fun i(
        tag: String,
        msg: String,
    ): Int =
        android.util.Log.i(tag, msg).also {
            sentryLog(SentryLogLevel.INFO, tag, msg)
        }

    fun w(
        tag: String,
        msg: String,
    ): Int =
        android.util.Log.w(tag, msg).also {
            Sentry.captureMessage("[$tag] $msg", SentryLevel.WARNING)
            sentryLog(SentryLogLevel.WARN, tag, msg)
        }

    fun w(
        tag: String,
        msg: String,
        tr: Throwable,
    ): Int =
        android.util.Log.w(tag, msg, tr).also {
            Sentry.captureException(tr) { scope -> scope.level = SentryLevel.WARNING }
            sentryLog(SentryLogLevel.WARN, tag, "$msg\n${android.util.Log.getStackTraceString(tr)}")
        }

    fun e(
        tag: String,
        msg: String,
    ): Int =
        android.util.Log.e(tag, msg).also {
            Sentry.captureMessage("[$tag] $msg", SentryLevel.ERROR)
            sentryLog(SentryLogLevel.ERROR, tag, msg)
        }

    fun e(
        tag: String,
        msg: String,
        tr: Throwable,
    ): Int =
        android.util.Log.e(tag, msg, tr).also {
            Sentry.captureException(tr)
            sentryLog(SentryLogLevel.ERROR, tag, "$msg\n${android.util.Log.getStackTraceString(tr)}")
        }

    private fun sentryLog(
        level: SentryLogLevel,
        tag: String,
        msg: String,
    ) {
        if (!streamingActive.get()) return
        if (level == SentryLogLevel.TRACE) return

        val attrs = synchronized(attributesLock) { attributes }
        val sentryAttrs =
            (
                attrs.map { (k, v) ->
                    SentryAttribute.stringAttribute(k, v)
                } + SentryAttribute.stringAttribute("tag", tag)
            ).toTypedArray()

        Sentry.logger().log(
            level,
            SentryLogParameters.create(SentryAttributes.of(*sentryAttrs)),
            msg,
        )
    }
}
