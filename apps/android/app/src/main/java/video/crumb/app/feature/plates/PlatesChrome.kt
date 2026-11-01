// SPDX-License-Identifier: AGPL-3.0-or-later

@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package video.crumb.app.feature.plates

import video.crumb.app.ui.CrumbFilterChip
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.InputChipDefaults
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SwitchColors
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Switch
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import video.crumb.app.ui.theme.LprAccent
import video.crumb.app.ui.theme.LprAccentChip
import video.crumb.app.ui.theme.LprAccentHot
import video.crumb.app.ui.theme.LprAccentInk
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary

/*
 * Minimal chrome for the Plates tab (1A): one search bar, and everything else
 * in a single filter sheet. A chip strip appears under the bar only while a
 * filter is off its default.
 */

private val SearchPillColor = Color(0xFF2E313A)
private val OutlineColor = Color(0xFF434854)
private val SheetColor = Color(0xFF24272E)

@Composable
internal fun lprSwitchColors(): SwitchColors = SwitchDefaults.colors(
    checkedThumbColor = LprAccentInk,
    checkedTrackColor = LprAccent,
    checkedBorderColor = LprAccent,
    uncheckedThumbColor = Color(0xFFC7CBD3),
    uncheckedTrackColor = Color(0xFF3A3F4B),
    uncheckedBorderColor = Color(0xFF5A6070),
)

@Composable
private fun lprChipColors() = FilterChipDefaults.filterChipColors(
    containerColor = Color.Transparent,
    labelColor = Color(0xFFD7DAE0),
    selectedContainerColor = LprAccentChip,
    selectedLabelColor = LprAccentHot,
    selectedLeadingIconColor = LprAccentHot,
)

@Composable
private fun lprChipBorder(selected: Boolean) = FilterChipDefaults.filterChipBorder(
    enabled = true,
    selected = selected,
    borderColor = OutlineColor,
    selectedBorderColor = Color.Transparent,
)

// ─── search bar ─────────────────────────────────────────────────────────────

/**
 * The single search affordance: a rounded bar with the filter icon (and its
 * count badge) and an overflow menu inside it. [compact] is the landscape
 * variant that rides in the top bar next to the mode tabs.
 */
@Composable
fun PlatesSearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    onSubmit: () -> Unit,
    activeFilters: Int,
    onOpenFilters: () -> Unit,
    onWatchlist: () -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = modifier
            .height(if (compact) 40.dp else 48.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(SearchPillColor)
            .padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = Color(0xFFC7CBD3), modifier = Modifier.size(22.dp))
        BasicTextField(
            value = query,
            onValueChange = onQueryChange,
            singleLine = true,
            textStyle = TextStyle(color = TextPrimary, fontSize = 15.sp),
            cursorBrush = SolidColor(LprAccent),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (query.isEmpty()) Text("Search plates", color = TextSecondary, fontSize = 15.sp, maxLines = 1)
                    inner()
                }
            },
        )
        if (query.isNotEmpty()) {
            IconButton(onClick = { onQueryChange(""); onSubmit() }, modifier = Modifier.size(40.dp)) {
                Icon(Icons.Filled.Close, contentDescription = "Clear search", tint = Color(0xFFC7CBD3), modifier = Modifier.size(20.dp))
            }
        }
        Box {
            IconButton(onClick = onOpenFilters, modifier = Modifier.size(44.dp)) {
                Icon(
                    Icons.Filled.Tune,
                    contentDescription = if (activeFilters > 0) "Filters, $activeFilters on" else "Filters",
                    tint = if (activeFilters > 0) LprAccentHot else Color(0xFFC7CBD3),
                )
            }
            if (activeFilters > 0) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = (-6).dp, y = 6.dp)
                        .size(16.dp)
                        .background(LprAccent, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        activeFilters.toString(),
                        color = LprAccentInk,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        }
        Box {
            IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(44.dp)) {
                Icon(Icons.Filled.MoreVert, contentDescription = "More", tint = Color(0xFFC7CBD3))
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(text = { Text("Watchlist") }, onClick = { menuOpen = false; onWatchlist() })
                DropdownMenuItem(text = { Text("Refresh") }, onClick = { menuOpen = false; onRefresh() })
            }
        }
    }
}

// ─── active filter strip ────────────────────────────────────────────────────

/** Dismissible chips for the filters that are off their default. Not drawn when there are none. */
@Composable
fun ActiveFilterStrip(
    chips: List<ActiveFilterChip>,
    onClear: (FilterKind) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (chips.isEmpty()) return
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        chips.forEach { chip ->
            // R3: the same chip component as Clips (28 dp variant), with a close icon.
            CrumbFilterChip(
                selected = true,
                onClick = { onClear(chip.kind) },
                label = chip.label,
                accent = LprAccent,
                compact = true,
                dismissible = true,
            )
        }
    }
}

// ─── filter sheet ───────────────────────────────────────────────────────────

/** Everything the filter sheet edits, passed down so the sheet stays a pure view. */
data class PlatesFilterSheetState(
    val cameras: List<Pair<String, String>>,
    val selectedCameraIds: Set<String>,
    val hours: Long,
    val anchorEndMs: Long?,
    val anchorLabel: String?,
    val match: String,
    val viewMode: PlatesViewMode,
    val hideRegulars: Boolean,
    val mergeDuplicates: Boolean,
    val anyActive: Boolean,
    val footer: String,
    val watchlistCount: Int,
)

/**
 * The one modal bottom sheet behind the filter icon: cameras, time range, "ends
 * at", match mode, view, Hide regulars and Merge duplicates. Changes apply as
 * they are made (the list behind updates); Done just closes.
 */
@Composable
fun PlatesFilterSheet(
    sheet: PlatesFilterSheetState,
    onCameras: (Set<String>) -> Unit,
    onHours: (Long) -> Unit,
    onPickEndsAt: () -> Unit,
    onResetEndsAt: () -> Unit,
    onMatch: (String) -> Unit,
    onViewMode: (PlatesViewMode) -> Unit,
    onHideRegulars: (Boolean) -> Unit,
    onMergeDuplicates: (Boolean) -> Unit,
    onReset: () -> Unit,
    onWatchlist: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SheetColor,
    ) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
        ) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Filters", color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                if (sheet.anyActive) {
                    TextButton(onClick = onReset) { Text("Reset", color = LprAccentHot) }
                }
            }

            SectionLabel("Cameras")
            val allIds = sheet.cameras.map { it.first }
            FlowRow(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                val allOn = allIds.isNotEmpty() && sheet.selectedCameraIds.containsAll(allIds)
                FilterChip(
                    selected = allOn,
                    onClick = { onCameras(allIds.toSet()) },
                    label = { Text("All cameras") },
                    leadingIcon = if (allOn) ({ Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }) else null,
                    colors = lprChipColors(),
                    border = lprChipBorder(allOn),
                    shape = RoundedCornerShape(8.dp),
                )
                sheet.cameras.forEach { (id, name) ->
                    val on = !allOn && id in sheet.selectedCameraIds
                    FilterChip(
                        selected = on,
                        onClick = { onCameras(toggleCameraSelection(allIds, sheet.selectedCameraIds, id)) },
                        label = { Text(name, maxLines = 1) },
                        leadingIcon = if (on) ({ Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }) else null,
                        colors = lprChipColors(),
                        border = lprChipBorder(on),
                        shape = RoundedCornerShape(8.dp),
                    )
                }
            }

            SectionLabel("Time range")
            val ranges = RANGE_SEGMENTS
            SegmentedRow(
                labels = ranges.map { it.second },
                selectedIndex = ranges.indexOfFirst { it.first == sheet.hours },
                onSelect = { onHours(ranges[it].first) },
            )
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .padding(horizontal = 24.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Ends at", color = TextPrimary, fontSize = 15.sp)
                    Text(
                        if (sheet.hours == 0L) "Not used with All time" else sheet.anchorLabel ?: "Now",
                        color = TextSecondary,
                        fontSize = 12.5.sp,
                    )
                }
                if (sheet.anchorEndMs != null && sheet.hours != 0L) {
                    TextButton(onClick = onResetEndsAt) { Text("Now", color = LprAccentHot) }
                }
                TextButton(onClick = onPickEndsAt, enabled = sheet.hours != 0L) {
                    Text("Pick a time", color = if (sheet.hours != 0L) LprAccentHot else TextSecondary)
                }
            }

            SectionLabel("Match")
            SegmentedRow(
                labels = MATCH_SEGMENTS.map { it.second },
                selectedIndex = MATCH_SEGMENTS.indexOfFirst { it.first == sheet.match },
                onSelect = { onMatch(MATCH_SEGMENTS[it].first) },
            )

            SectionLabel("View")
            val modes = PlatesViewMode.entries
            SegmentedRow(
                labels = modes.map { it.label },
                selectedIndex = modes.indexOf(sheet.viewMode),
                onSelect = { onViewMode(modes[it]) },
            )

            SwitchRow(
                title = "Hide regulars",
                subtitle = "Plates seen often in the last 30 days. Watchlisted plates always show.",
                checked = sheet.hideRegulars,
                onChange = onHideRegulars,
            )
            SwitchRow(
                title = "Merge duplicates",
                subtitle = "Repeat reads of one pass become one row.",
                checked = sheet.mergeDuplicates,
                onChange = onMergeDuplicates,
            )

            if (sheet.footer.isNotBlank()) {
                Text(
                    sheet.footer,
                    color = TextSecondary,
                    fontSize = 12.5.sp,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 6.dp),
                )
            }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onWatchlist) {
                    Text(
                        if (sheet.watchlistCount > 0) "Watchlist (${sheet.watchlistCount})" else "Watchlist",
                        color = LprAccentHot,
                    )
                }
                Spacer(Modifier.size(8.dp))
                androidx.compose.material3.Button(
                    onClick = onDismiss,
                    colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = LprAccent, contentColor = LprAccentInk),
                ) { Text("Done") }
            }
        }
    }
}

/** Time-range segments (hours, label). Maps onto [PLATES_RANGE_OPTIONS]; 3 days is left to the chip strip. */
internal val RANGE_SEGMENTS: List<Pair<Long, String>> = listOf(
    1L to "1 h",
    6L to "6 h",
    24L to "24 h",
    168L to "7 d",
    720L to "30 d",
    0L to "All",
)

private val MATCH_SEGMENTS: List<Pair<String, String>> = listOf(
    "exact" to "Exact",
    "contains" to "Contains",
    "fuzzy" to "Fuzzy",
)

@Composable
private fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        color = TextSecondary,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.7.sp,
        modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 12.dp, bottom = 6.dp),
    )
}

/** A pill-shaped single-choice row. Selected segment gets the accent wash. */
@Composable
internal fun SegmentedRow(
    labels: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .padding(horizontal = 24.dp, vertical = 2.dp)
            .fillMaxWidth()
            .height(40.dp)
            .clip(RoundedCornerShape(20.dp))
            .border(BorderStroke(1.dp, OutlineColor), RoundedCornerShape(20.dp)),
    ) {
        labels.forEachIndexed { i, label ->
            val on = i == selectedIndex
            Box(
                Modifier
                    .weight(1f)
                    .height(40.dp)
                    .background(if (on) LprAccentChip else Color.Transparent)
                    .clickable(role = Role.RadioButton) { onSelect(i) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    color = if (on) LprAccentHot else Color(0xFFD7DAE0),
                    fontSize = 13.sp,
                    fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium,
                    maxLines = 1,
                )
            }
            if (i < labels.lastIndex) {
                Box(Modifier.width(1.dp).height(40.dp).background(OutlineColor))
            }
        }
    }
}

@Composable
private fun SwitchRow(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable { onChange(!checked) }
            .padding(horizontal = 24.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = TextPrimary, fontSize = 15.sp)
            Text(subtitle, color = TextSecondary, fontSize = 12.5.sp)
        }
        Switch(checked = checked, onCheckedChange = onChange, colors = lprSwitchColors())
    }
}
