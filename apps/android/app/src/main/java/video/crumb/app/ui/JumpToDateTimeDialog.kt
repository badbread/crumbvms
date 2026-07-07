// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimeInput
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import java.util.Calendar
import java.util.TimeZone

/**
 * A reliable "jump to date & time" picker: a Material3 date step, then a compact
 * time step, returning the chosen instant in epoch-millis (device-local zone).
 *
 * This replaces the old native `DatePickerDialog` → `TimePickerDialog` chain, whose
 * `datePickerMode=spinner` theme was flaky on modern Android (the date step's OK
 * never advanced to the time step — so the picker "only picked date"). Material3's
 * Compose pickers are self-contained, themed by the app's color scheme, and survive
 * rotation, so both steps always work.
 *
 * @param initialMs Pre-selects this instant in both steps.
 * @param onDismiss Cancelled / dismissed without choosing.
 * @param onPicked  Called once with the combined date+time as epoch-millis.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JumpToDateTimeDialog(
    initialMs: Long,
    onDismiss: () -> Unit,
    onPicked: (Long) -> Unit,
) {
    val initCal = remember(initialMs) { Calendar.getInstance().apply { timeInMillis = initialMs } }
    var pickingTime by rememberSaveable { mutableStateOf(false) }
    val dateState = rememberDatePickerState(initialSelectedDateMillis = initialMs)
    val timeState = rememberTimePickerState(
        initialHour = initCal.get(Calendar.HOUR_OF_DAY),
        initialMinute = initCal.get(Calendar.MINUTE),
        is24Hour = true,
    )

    if (!pickingTime) {
        DatePickerDialog(
            onDismissRequest = onDismiss,
            confirmButton = {
                TextButton(
                    onClick = { pickingTime = true },
                    enabled = dateState.selectedDateMillis != null,
                ) { Text("Next") }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        ) {
            DatePicker(state = dateState)
        }
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Jump to time") },
            text = {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    TimeInput(state = timeState)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val dateMs = dateState.selectedDateMillis ?: initialMs
                    // Material3's date picker reports the selection as UTC midnight,
                    // so read Y/M/D in UTC, then combine with the chosen LOCAL h:m.
                    val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
                        .apply { timeInMillis = dateMs }
                    val target = Calendar.getInstance().apply {
                        set(
                            utc.get(Calendar.YEAR),
                            utc.get(Calendar.MONTH),
                            utc.get(Calendar.DAY_OF_MONTH),
                            timeState.hour,
                            timeState.minute,
                            0,
                        )
                        set(Calendar.MILLISECOND, 0)
                    }.timeInMillis
                    onPicked(target)
                }) { Text("Go") }
            },
            dismissButton = { TextButton(onClick = { pickingTime = false }) { Text("Back") } },
        )
    }
}
