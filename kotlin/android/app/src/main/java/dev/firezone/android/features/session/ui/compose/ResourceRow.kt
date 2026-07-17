// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.features.session.ui.ResourceUiModel
import dev.firezone.android.features.session.ui.isInternetResource
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.StatusEnum

@Composable
fun ResourceRow(
    resource: ResourceUiModel,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(16.dp),
    ) {
        Text(text = resource.displayName, style = MaterialTheme.typography.bodyLarge)
        if (!resource.isInternetResource()) {
            resource.address?.let { address ->
                Text(
                    text = address,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun ResourceRowPreview() {
    FirezoneTheme {
        Column {
            ResourceRow(
                resource =
                    ResourceUiModel(
                        Resource(
                            type = ResourceType.DNS,
                            id = "1",
                            address = "gitlab.example.com",
                            addressDescription = null,
                            sites = null,
                            name = "GitLab",
                            status = StatusEnum.ONLINE,
                        ),
                        ResourceState.ENABLED,
                    ),
                onClick = {},
            )
            HorizontalDivider()
            ResourceRow(
                resource =
                    ResourceUiModel(
                        Resource(
                            type = ResourceType.Internet,
                            id = "2",
                            address = null,
                            addressDescription = null,
                            sites = null,
                            name = "Internet Resource",
                            status = StatusEnum.ONLINE,
                        ),
                        ResourceState.ENABLED,
                    ),
                onClick = {},
            )
        }
    }
}
