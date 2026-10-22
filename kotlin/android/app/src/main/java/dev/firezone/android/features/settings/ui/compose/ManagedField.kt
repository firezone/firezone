// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.ui.FirezoneIcons

@Composable
fun ManagedTextField(
    label: String,
    value: String,
    isManaged: Boolean,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            label = { Text(label) },
            enabled = !isManaged,
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            modifier = Modifier.weight(1f),
        )
        if (isManaged) {
            ManagedByOrganizationIcon()
        }
    }
}

@Composable
fun ManagedSwitchRow(
    label: String,
    checked: Boolean,
    isManaged: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val explanation = stringResource(R.string.managed_setting_info_description)
    val context = LocalContext.current
    // Inside the toggle, so that a tap on a managed row reaches the explanation first.
    val explainOnTap =
        if (isManaged) {
            Modifier.clickable { Toast.makeText(context, explanation, Toast.LENGTH_SHORT).show() }
        } else {
            Modifier
        }

    Row(
        modifier
            .fillMaxWidth()
            .toggleable(value = checked, enabled = !isManaged, role = Role.Switch, onValueChange = onCheckedChange)
            .then(explainOnTap)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text = label, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = null, enabled = !isManaged)
    }
}

@Composable
private fun ManagedByOrganizationIcon(modifier: Modifier = Modifier) {
    val explanation = stringResource(R.string.managed_setting_info_description)
    val context = LocalContext.current

    IconButton(
        onClick = { Toast.makeText(context, explanation, Toast.LENGTH_SHORT).show() },
        modifier = modifier,
    ) {
        Icon(imageVector = FirezoneIcons.Info, contentDescription = explanation)
    }
}
