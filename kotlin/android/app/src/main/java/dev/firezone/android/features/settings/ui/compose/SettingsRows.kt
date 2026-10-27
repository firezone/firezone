// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui.compose

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.firezone.android.R
import dev.firezone.android.ui.FirezoneIcons
import kotlinx.collections.immutable.ImmutableList

/** A category header over rows drawn as one rounded block, the way the system Settings app groups them. */
@Composable
fun SettingsGroup(
    modifier: Modifier = Modifier,
    title: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(modifier) {
        if (title != null) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier =
                    Modifier
                        .padding(start = 16.dp, top = 8.dp, bottom = 8.dp)
                        .semantics { heading() },
            )
        }
        Column(
            Modifier.clip(RoundedCornerShape(24.dp)),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            content = content,
        )
    }
}

/** One row of a [SettingsGroup]; [action] goes inside the row's shape so its ripple does too. */
@Composable
fun SettingsRowContainer(
    modifier: Modifier = Modifier,
    action: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(4.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .then(action)
            .heightIn(min = 56.dp)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        content = content,
    )
}

@Composable
fun SettingsRow(
    title: String,
    modifier: Modifier = Modifier,
    action: Modifier = Modifier,
    summary: String? = null,
    isManaged: Boolean = false,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    SettingsRowContainer(modifier, action) {
        Column(
            Modifier
                .weight(1f)
                .alpha(if (isManaged) DISABLED_ALPHA else 1f),
        ) {
            Text(text = title, style = MaterialTheme.typography.bodyLarge)
            if (!summary.isNullOrEmpty()) {
                Text(
                    text = summary,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        trailing()
        if (isManaged) {
            ManagedByOrganizationIcon(Modifier.offset(x = ICON_BUTTON_INSET))
        }
    }
}

/** Shows [value] and edits it in a dialog, staging the result through [onValueChange] once confirmed. */
@Composable
fun TextPreferenceRow(
    title: String,
    value: String,
    isManaged: Boolean,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    isValid: (String) -> Boolean = { true },
) {
    var isEditing by rememberSaveable { mutableStateOf(false) }

    SettingsRow(
        title = title,
        summary = value,
        isManaged = isManaged,
        modifier = modifier,
        action = Modifier.clickable(enabled = !isManaged) { isEditing = true },
    )

    if (isEditing) {
        var draft by rememberSaveable(stateSaver = TextFieldValue.Saver) {
            mutableStateOf(TextFieldValue(value, TextRange(value.length)))
        }
        val isDraftValid = isValid(draft.text)
        val confirm = {
            onValueChange(draft.text)
            isEditing = false
        }
        val focusRequester = remember { FocusRequester() }

        AlertDialog(
            onDismissRequest = { isEditing = false },
            title = { Text(title) },
            text = {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    isError = !isDraftValid,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { if (isDraftValid) confirm() }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
                )
            },
            confirmButton = {
                TextButton(onClick = confirm, enabled = isDraftValid) {
                    Text(stringResource(android.R.string.ok))
                }
            },
            dismissButton = {
                TextButton(onClick = { isEditing = false }) {
                    Text(stringResource(android.R.string.cancel))
                }
            },
        )

        LaunchedEffect(Unit) { focusRequester.requestFocus() }
    }
}

@Composable
fun <T> ChoicePreferenceRow(
    title: String,
    options: ImmutableList<T>,
    selected: T,
    optionLabel: @Composable (T) -> String,
    isManaged: Boolean,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    var isChoosing by rememberSaveable { mutableStateOf(false) }

    SettingsRow(
        title = title,
        summary = optionLabel(selected),
        isManaged = isManaged,
        modifier = modifier,
        action = Modifier.clickable(enabled = !isManaged) { isChoosing = true },
    )

    if (isChoosing) {
        AlertDialog(
            onDismissRequest = { isChoosing = false },
            title = { Text(title) },
            text = {
                Column(Modifier.selectableGroup()) {
                    options.forEach { option ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .selectable(selected = option == selected, role = Role.RadioButton) {
                                    onSelect(option)
                                    isChoosing = false
                                },
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            RadioButton(selected = option == selected, onClick = null)
                            Text(optionLabel(option), style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { isChoosing = false }) {
                    Text(stringResource(android.R.string.cancel))
                }
            },
        )
    }
}

@Composable
fun SwitchPreferenceRow(
    title: String,
    checked: Boolean,
    isManaged: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    SettingsRow(
        title = title,
        isManaged = isManaged,
        modifier = modifier,
        action = Modifier.toggleable(value = checked, enabled = !isManaged, role = Role.Switch, onValueChange = onCheckedChange),
    ) {
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

private const val DISABLED_ALPHA = 0.38f

// Lines the glyph of a trailing icon button up with the row's padding rather than its touch target.
internal val ICON_BUTTON_INSET = 12.dp
