/* Licensed under Apache 2.0 (C) 2015 Firezone, Inc. */
package dev.firezone.android.util

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build

class CustomTabsHelper {
    companion object {
        val STABLE_PACKAGE = "com.android.chrome"
        val BETA_PACKAGE = "com.chrome.beta"
        val DEV_PACKAGE = "com.chrome.dev"
        val LOCAL_PACKAGE = "com.google.android.apps.chrome"
        val ACTION_CUSTOM_TABS_CONNECTION = "android.support.customtabs.action.CustomTabsService"

        private var sPackageNameToUse: String? = null

        fun getPackageNameToUse(context: Context): String? {
            if (sPackageNameToUse != null) return sPackageNameToUse
            val pm = context.getPackageManager()
            val activityIntent = Intent(Intent.ACTION_VIEW, Uri.parse("http://www.example.com"))
            val defaultViewHandlerInfo = pm.resolveActivity(activityIntent, 0)
            var defaultViewHandlerPackageName: String? = null
            if (defaultViewHandlerInfo != null) {
                defaultViewHandlerPackageName = defaultViewHandlerInfo.activityInfo.packageName
            }
            val resolvedActivityList = pm.queryIntentActivities(activityIntent, 0)
            val packagesSupportingCustomTabs: MutableList<String> = ArrayList()
            for (info in resolvedActivityList) {
                val serviceIntent = Intent()
                serviceIntent.action = ACTION_CUSTOM_TABS_CONNECTION
                serviceIntent.setPackage(info.activityInfo.packageName)
                if (pm.resolveService(serviceIntent, 0) != null) {
                    packagesSupportingCustomTabs.add(info.activityInfo.packageName)
                }
            }
            if (packagesSupportingCustomTabs.size == 1) {
                sPackageNameToUse = packagesSupportingCustomTabs.get(0)
            } else if (packagesSupportingCustomTabs.contains(STABLE_PACKAGE)) {
                sPackageNameToUse = STABLE_PACKAGE
            } else if (packagesSupportingCustomTabs.contains(BETA_PACKAGE)) {
                sPackageNameToUse = BETA_PACKAGE
            } else if (packagesSupportingCustomTabs.contains(DEV_PACKAGE)) {
                sPackageNameToUse = DEV_PACKAGE
            } else if (packagesSupportingCustomTabs.contains(LOCAL_PACKAGE)) {
                sPackageNameToUse = LOCAL_PACKAGE
            }
            return sPackageNameToUse
        }

        fun checkIfChromeAppIsDefault() =
            sPackageNameToUse == STABLE_PACKAGE ||
                sPackageNameToUse == BETA_PACKAGE ||
                sPackageNameToUse == DEV_PACKAGE ||
                sPackageNameToUse == LOCAL_PACKAGE

        fun checkIfChromeIsInstalled(context: Context): Boolean = try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageInfo(STABLE_PACKAGE, PackageManager.PackageInfoFlags.of(0L))
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(STABLE_PACKAGE, 0)
            }
            info.applicationInfo.enabled
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }
}
