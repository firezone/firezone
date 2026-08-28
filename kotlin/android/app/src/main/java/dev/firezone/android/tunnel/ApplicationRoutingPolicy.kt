// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import dev.firezone.android.core.data.model.ManagedConfiguration

internal enum class ApplicationRoutingMode {
    ALLOW,
    DISALLOW,
}

internal data class ApplicationRoutingPolicy(
    val mode: ApplicationRoutingMode,
    val packageNames: List<String>,
    val hasConflict: Boolean,
)

internal fun ManagedConfiguration.applicationRoutingPolicy(): ApplicationRoutingPolicy {
    val allowed = allowedApplications.toPackageNames()
    val disallowed = disallowedApplications.toPackageNames()

    return if (allowed.isNotEmpty()) {
        ApplicationRoutingPolicy(
            mode = ApplicationRoutingMode.ALLOW,
            packageNames = allowed.filterNot { it in NEVER_TUNNEL_APPLICATIONS },
            hasConflict = disallowed.isNotEmpty(),
        )
    } else {
        ApplicationRoutingPolicy(
            mode = ApplicationRoutingMode.DISALLOW,
            packageNames = (disallowed + NEVER_TUNNEL_APPLICATIONS).distinct(),
            hasConflict = false,
        )
    }
}

internal fun ApplicationRoutingPolicy.apply(
    addAllowed: (String) -> Boolean,
    addDisallowed: (String) -> Boolean,
): Boolean =
    when (mode) {
        ApplicationRoutingMode.ALLOW -> {
            var applied = 0
            packageNames.forEach { packageName ->
                if (addAllowed(packageName)) {
                    applied += 1
                }
            }
            applied > 0
        }

        ApplicationRoutingMode.DISALLOW -> {
            packageNames.forEach { packageName -> addDisallowed(packageName) }
            true
        }
    }

private fun String?.toPackageNames(): List<String> =
    this
        ?.split(",")
        ?.map(String::trim)
        ?.filter(String::isNotEmpty)
        ?.distinct()
        .orEmpty()

private val NEVER_TUNNEL_APPLICATIONS =
    listOf(
        "com.google.android.gms",
        "com.google.firebase.messaging",
        "com.google.android.gsf",
    )
