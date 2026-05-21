// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import android.net.Uri
import android.widget.Toast
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.isEnabled
import dev.firezone.android.features.session.ui.ResourceViewModel
import dev.firezone.android.features.session.ui.isInternetResource
import dev.firezone.android.tunnel.model.StatusEnum

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ResourceDetailsSheet(
    resource: ResourceViewModel,
    isFavorite: Boolean,
    onAddFavorite: () -> Unit,
    onRemoveFavorite: () -> Unit,
    onToggleInternet: () -> ResourceState,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState()
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(Modifier.fillMaxWidth().padding(16.dp)) {
            if (resource.isInternetResource()) {
                InternetResourceDetails(resource, onToggleInternet)
            } else {
                NonInternetResourceDetails(resource, isFavorite, onAddFavorite, onRemoveFavorite)
            }
            resource.sites?.firstOrNull()?.let { site ->
                SiteSection(siteName = site.name, status = resource.status)
            }
        }
    }
}

@Composable
private fun NonInternetResourceDetails(
    resource: ResourceViewModel,
    isFavorite: Boolean,
    onAddFavorite: () -> Unit,
    onRemoveFavorite: () -> Unit,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    SectionLabel("Resource")

    DetailRow(label = "Name:") {
        Text(
            text = resource.name,
            modifier =
                Modifier.clickable {
                    clipboard.setText(AnnotatedString(resource.name))
                    Toast.makeText(context, "Name copied to clipboard", Toast.LENGTH_SHORT).show()
                },
        )
    }

    val displayAddress = resource.addressDescription ?: resource.address
    val addressUri = resource.addressDescription?.let { Uri.parse(it) }
    val isUrl = addressUri?.scheme != null

    DetailRow(label = "Address:") {
        Text(
            text = displayAddress.orEmpty(),
            color = if (isUrl) Color.Blue else MaterialTheme.colorScheme.onSurface,
            fontStyle = if (isUrl) FontStyle.Italic else FontStyle.Normal,
            modifier =
                Modifier.clickable {
                    if (isUrl) {
                        addressUri?.let { CustomTabsIntent.Builder().build().launchUrl(context, it) }
                    } else if (displayAddress != null) {
                        clipboard.setText(AnnotatedString(displayAddress))
                        Toast.makeText(context, "Address copied to clipboard", Toast.LENGTH_SHORT).show()
                    }
                },
        )
    }

    if (isFavorite) {
        OutlinedButton(onClick = onRemoveFavorite, modifier = Modifier.fillMaxWidth()) {
            Text("Remove from Favorites")
        }
    } else {
        OutlinedButton(onClick = onAddFavorite, modifier = Modifier.fillMaxWidth()) {
            Text("Add to Favorites")
        }
    }
}

@Composable
private fun InternetResourceDetails(
    resource: ResourceViewModel,
    onToggleInternet: () -> ResourceState,
) {
    var state by remember(resource.id) { mutableStateOf(resource.state) }

    SectionLabel("Resource")
    DetailRow(label = "Name:") { Text(resource.name) }
    DetailRow(label = "Description:") { Text("All network traffic") }

    OutlinedButton(
        onClick = { state = onToggleInternet() },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(if (state.isEnabled()) "Disable this resource" else "Enable this resource")
    }
}

@Composable
private fun SiteSection(
    siteName: String,
    status: StatusEnum,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    SectionLabel("Site")
    DetailRow(label = "Name:") {
        Text(
            text = siteName,
            modifier =
                Modifier.clickable {
                    clipboard.setText(AnnotatedString(siteName))
                    Toast.makeText(context, "Site name copied to clipboard", Toast.LENGTH_SHORT).show()
                },
        )
    }

    val statusText =
        when (status) {
            StatusEnum.ONLINE -> "Gateway connected"
            StatusEnum.OFFLINE -> "All Gateways offline"
            StatusEnum.UNKNOWN -> "No activity"
        }
    val dotColor =
        when (status) {
            StatusEnum.ONLINE -> Color.Green
            StatusEnum.OFFLINE -> Color.Red
            StatusEnum.UNKNOWN -> Color.Gray
        }

    DetailRow(label = "Status:") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).background(dotColor, CircleShape))
            Spacer(Modifier.width(8.dp))
            Text(text = statusText)
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleLarge,
        modifier = Modifier.padding(bottom = 8.dp),
    )
}

@Composable
private fun DetailRow(
    label: String,
    value: @Composable () -> Unit,
) {
    Row(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
        Text(text = label, fontWeight = FontWeight.Bold, modifier = Modifier.padding(end = 8.dp))
        value()
    }
}
