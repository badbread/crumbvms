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
 * @param preserveSeconds Carry the seconds (and milliseconds) of [initialMs]
 *   through to the result instead of truncating to the minute. The M3 time step
 *   only offers hours and minutes, so an export boundary picked from a
 *   second-accurate selection would otherwise silently lose its seconds. Off by
 *   default: jumping the playhead to a whole minute is the desired behaviour there.
 * @param title Heading for the time step.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JumpToDateTimeDialog(
    initialMs: Long,
    onDismiss: () -> Unit,
    onPicked: (Long) -> Unit,
    preserveSeconds: Boolean = false,
    title: String = "Jump to time",
) {
    val initCal = remember(initialMs) { Calendar.getInstance().apply { timeInMillis = initialMs } }
    var pickingTime by rememberSaveable { mutableStateOf(false) }
    val dateState = rememberDatePickerState(
        initialSelectedDateMillis = localDateAsPickerMillis(initialMs),
    )
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
            title = { Text(title) },
            text = {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    TimeInput(state = timeState)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val dateMs = dateState.selectedDateMillis ?: localDateAsPickerMillis(initialMs)
                    val target = combinePickerDateWithLocalTime(
                        pickerDateMs = dateMs,
                        hour = timeState.hour,
                        minute = timeState.minute,
                        second = if (preserveSeconds) initCal.get(Calendar.SECOND) else 0,
                        millis = if (preserveSeconds) initCal.get(Calendar.MILLISECOND) else 0,
                    )
                    onPicked(target)
                }) { Text("Go") }
            },
            dismissButton = { TextButton(onClick = { pickingTime = false }) { Text("Back") } },
        )
    }
}

/**
 * The value to hand Material3's DatePicker as `selectedDateMillis` for an
 * instant: the instant's LOCAL calendar date expressed as UTC midnight. The
 * picker reads that value in UTC, so passing the raw instant preselects the
 * wrong day for any local time that falls on a different UTC date (evenings in
 * the Americas, mornings in UTC+ zones).
 */
internal fun localDateAsPickerMillis(instantMs: Long, zone: TimeZone = TimeZone.getDefault()): Long {
    val local = Calendar.getInstance(zone).apply { timeInMillis = instantMs }
    return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
        clear()
        set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH))
    }.timeInMillis
}

/**
 * Inverse of [localDateAsPickerMillis]: read the picker's selection (UTC
 * midnight of the chosen date) as Y/M/D and combine it with the chosen LOCAL
 * time of day, returning the instant in epoch-millis.
 */
internal fun combinePickerDateWithLocalTime(
    pickerDateMs: Long,
    hour: Int,
    minute: Int,
    second: Int,
    millis: Int,
    zone: TimeZone = TimeZone.getDefault(),
): Long {
    val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = pickerDateMs }
    return Calendar.getInstance(zone).apply {
        clear()
        set(utc.get(Calendar.YEAR), utc.get(Calendar.MONTH), utc.get(Calendar.DAY_OF_MONTH), hour, minute, second)
        set(Calendar.MILLISECOND, millis)
    }.timeInMillis
}
