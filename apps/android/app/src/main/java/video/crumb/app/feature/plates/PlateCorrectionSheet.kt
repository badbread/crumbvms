// SPDX-License-Identifier: AGPL-3.0-or-later

@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package video.crumb.app.feature.plates

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import video.crumb.app.ui.theme.JetBrainsMono
import video.crumb.app.ui.theme.LprAccent
import video.crumb.app.ui.theme.LprAccentChip
import video.crumb.app.ui.theme.LprAccentHot
import video.crumb.app.ui.theme.LprAccentInk
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary

/**
 * "Correct plate" (admin-only, issue #673): tell Crumb that a misread plate is
 * really another plate, so the two count as one vehicle everywhere. The server
 * does the work (an alias row); raw reads are never rewritten, which is why
 * Undo is just deleting the alias.
 */
@Composable
fun PlateCorrectionSheet(
    ui: PlateCorrectionUi,
    onSubmit: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var typed by remember(ui.plate) { mutableStateOf("") }
    val info = ui.suggestions
    val target = normalizePlateInput(typed)
    val effect = plateCorrectionEffect(
        from = ui.plate,
        target = target,
        reads = info?.reads ?: 0,
        movingAliases = info?.aliases.orEmpty(),
    )
    ModalBottomSheet(
        onDismissRequest = { if (!ui.saving) onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xFF24272E),
    ) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .imePadding()
                .navigationBarsPadding()
                .padding(horizontal = 24.dp)
                .padding(bottom = 16.dp),
        ) {
            Text("Correct plate ${ui.plate}", color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(
                "If the camera misread this plate, enter the real one. Every read of ${ui.plate} will count " +
                    "as that plate from now on. The original reads are kept and you can undo this later.",
                color = Color(0xFFC7CBD3),
                fontSize = 13.5.sp,
                modifier = Modifier.padding(top = 8.dp, bottom = 12.dp),
            )

            if (ui.unsupported) {
                Text("This server cannot correct plates yet. Update it.", color = MaterialTheme.colorScheme.error, fontSize = 13.5.sp)
            } else {
                OutlinedTextField(
                    value = typed,
                    onValueChange = { typed = normalizePlateInput(it).take(12) },
                    label = { Text("Real plate") },
                    singleLine = true,
                    textStyle = TextStyle(fontFamily = JetBrainsMono, fontWeight = FontWeight.Bold, fontSize = 16.sp, letterSpacing = 1.3.sp),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = LprAccent,
                        focusedLabelColor = LprAccentHot,
                        cursorColor = LprAccent,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )

                when {
                    ui.loading -> Row(Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), color = LprAccent, strokeWidth = 2.dp)
                        Text("  Looking for likely matches", color = TextSecondary, fontSize = 12.5.sp)
                    }
                    info != null && info.suggestions.isNotEmpty() -> {
                        Text(
                            "Likely matches, seen in your cameras",
                            color = TextSecondary,
                            fontSize = 12.5.sp,
                            modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
                        )
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            info.suggestions.forEach { s ->
                                val on = target == s.plate
                                FilterChip(
                                    selected = on,
                                    onClick = { typed = s.plate },
                                    label = {
                                        Text(
                                            buildString {
                                                append(s.plate)
                                                s.displayName?.takeIf { it.isNotBlank() }?.let { append("  ").append(it) }
                                            },
                                            fontFamily = JetBrainsMono,
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 13.sp,
                                        )
                                    },
                                    colors = FilterChipDefaults.filterChipColors(
                                        selectedContainerColor = LprAccentChip,
                                        selectedLabelColor = LprAccentHot,
                                    ),
                                    shape = RoundedCornerShape(8.dp),
                                )
                            }
                        }
                    }
                }
                if (effect != null) {
                    Text(effect, color = TextSecondary, fontSize = 12.5.sp, modifier = Modifier.padding(top = 10.dp))
                }
            }
            ui.error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
            }

            Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss, enabled = !ui.saving) { Text("Cancel", color = LprAccentHot) }
                Button(
                    onClick = { onSubmit(target) },
                    enabled = effect != null && !ui.saving && !ui.unsupported,
                    colors = ButtonDefaults.buttonColors(containerColor = LprAccent, contentColor = LprAccentInk),
                ) {
                    if (ui.saving) CircularProgressIndicator(Modifier.size(16.dp), color = LprAccentInk, strokeWidth = 2.dp) else Text("Correct")
                }
            }
        }
    }
}
