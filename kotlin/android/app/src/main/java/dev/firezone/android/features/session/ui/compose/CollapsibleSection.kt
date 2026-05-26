// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import dev.firezone.android.R

private val LiveGreen = Color(0xFF22A559)

/**
 * Emits a collapsible section into a [androidx.compose.foundation.lazy.LazyColumn]: an animated
 * header row followed by its [entries] (each animating in/out) when [expanded]. Used for both
 * Resources and Connected Devices.
 */
fun <T> LazyListScope.collapsibleSection(
    title: String,
    entries: List<T>,
    expanded: Boolean,
    onToggle: () -> Unit,
    key: (T) -> Any,
    live: Boolean = false,
    row: @Composable (T) -> Unit,
) {
    item(key = "header-$title") {
        SectionHeader(title = title, count = entries.size, expanded = expanded, live = live, onToggle = onToggle)
    }
    if (expanded) {
        items(entries, key = key) { entry ->
            Column(Modifier.fillMaxWidth().animateItem()) {
                row(entry)
            }
        }
    }
}

@Composable
fun SectionHeader(
    title: String,
    count: Int,
    expanded: Boolean,
    live: Boolean,
    onToggle: () -> Unit,
) {
    val rotation by animateFloatAsState(targetValue = if (expanded) 0f else -90f, label = "chevron")

    val countScale = remember { Animatable(1f) }
    var previousCount by remember { mutableIntStateOf(count) }
    LaunchedEffect(count) {
        if (count != previousCount) {
            previousCount = count
            countScale.animateTo(1.4f, tween(120))
            countScale.animateTo(1f, tween(180))
        }
    }

    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(vertical = 12.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painter = painterResource(R.drawable.ic_expand_more),
            contentDescription = null,
            modifier = Modifier.size(20.dp).rotate(rotation),
        )
        Spacer(Modifier.width(8.dp))
        Text(text = title, style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.width(8.dp))
        Text(
            text = count.toString(),
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.scale(countScale.value),
        )
        if (live) {
            Spacer(Modifier.width(8.dp))
            LiveDot()
        }
    }
}

@Composable
fun LiveDot(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "pulse")
    val ring by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1800), RepeatMode.Restart),
        label = "ring",
    )
    Canvas(modifier.size(16.dp)) {
        val r = size.minDimension / 4f
        drawCircle(color = LiveGreen.copy(alpha = (1f - ring) * 0.6f), radius = r + r * 2f * ring, center = center)
        drawCircle(color = LiveGreen, radius = r, center = center)
    }
}

@androidx.compose.ui.tooling.preview.Preview(showBackground = true)
@Composable
private fun SectionHeaderPreview() {
    FirezoneTheme {
        Column {
            SectionHeader(title = "Resources", count = 4, expanded = true, live = false, onToggle = {})
            SectionHeader(title = "Connected Devices", count = 2, expanded = false, live = true, onToggle = {})
        }
    }
}
