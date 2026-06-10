// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable
fun SectionLabel(
    text: String,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleLarge,
        modifier = modifier.padding(bottom = 8.dp),
    )
}

@Composable
fun DetailRow(
    label: String,
    modifier: Modifier = Modifier,
    value: @Composable () -> Unit,
) {
    Row(modifier.fillMaxWidth().padding(bottom = 8.dp)) {
        Text(text = label, fontWeight = FontWeight.Bold, modifier = Modifier.padding(end = 8.dp))
        value()
    }
}
