// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import video.crumb.app.ui.theme.TextSecondary
import java.time.Instant

/**
 * The shared "Add bookmark" dialog — used by both the Playback transport and the
 * Clips player so the two never drift. Description + an opt-in "Protect from
 * auto-delete" section (default OFF; 7 days / 1 min before / 5 min after).
 *
 * The caller owns the actual create call + feedback: [onConfirm] receives the
 * note and, when protection is enabled, the clamped `(days, preSeconds,
 * postSeconds)` — all `null` when protection is off.
 */
@Composable
fun AddBookmarkDialog(
    atMs: Long,
    initialDescription: String = "",
    onConfirm: (
        description: String,
        protectDays: Int?,
        protectPreSeconds: Int?,
        protectPostSeconds: Int?,
    ) -> Unit,
    onDismiss: () -> Unit,
) {
    var desc by remember { mutableStateOf(initialDescription) }
    var protect by remember { mutableStateOf(false) }
    var days by remember { mutableStateOf("7") }
    var preMin by remember { mutableStateOf("1") }
    var postMin by remember { mutableStateOf("5") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add bookmark") },
        text = {
            Column {
                Text(
                    Time.dateTime(Instant.ofEpochMilli(atMs)),
                    style = MaterialTheme.typography.bodyMedium,
                    color = TextSecondary,
                )
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = desc,
                    onValueChange = { desc = it },
                    label = { Text("Description (optional)") },
                    minLines = 2,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = protect, onCheckedChange = { protect = it })
                    Text("Protect from auto-delete", style = MaterialTheme.typography.bodyMedium)
                }
                if (protect) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        OutlinedTextField(
                            value = days,
                            onValueChange = { days = it.filter(Char::isDigit).take(2) },
                            label = { Text("Days") },
                            singleLine = true,
                            modifier = Modifier.width(82.dp),
                        )
                        OutlinedTextField(
                            value = preMin,
                            onValueChange = { preMin = it.filter(Char::isDigit).take(2) },
                            label = { Text("Min before") },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                        OutlinedTextField(
                            value = postMin,
                            onValueChange = { postMin = it.filter(Char::isDigit).take(2) },
                            label = { Text("Min after") },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    Text(
                        "Keeps a clip around this moment from auto-delete (1–30 days).",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                if (protect) {
                    val d = days.toIntOrNull()?.coerceIn(1, 30) ?: 7
                    val pre = (preMin.toIntOrNull()?.coerceIn(0, 60) ?: 1) * 60
                    val post = (postMin.toIntOrNull()?.coerceIn(0, 60) ?: 5) * 60
                    onConfirm(desc, d, pre, post)
                } else {
                    onConfirm(desc, null, null, null)
                }
            }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
