// SPDX-License-Identifier: AGPL-3.0-or-later

@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package video.crumb.app.feature.plates

import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayCircleOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import video.crumb.app.data.MediaUrls
import video.crumb.app.data.PlateAliasDto
import video.crumb.app.data.PlateStatsDto
import video.crumb.app.data.PlateWatchlistEntry
import video.crumb.app.ui.Time
import video.crumb.app.ui.theme.JetBrainsMono
import video.crumb.app.ui.theme.LprAccent
import video.crumb.app.ui.theme.LprAccentChip
import video.crumb.app.ui.theme.LprAccentHot
import video.crumb.app.ui.theme.LprWatchAmber
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary
import java.time.Instant
import java.time.ZoneId

private val CardColor = Color(0xFF1E2026)
private val BarBase = Color(0xFF4A5366)
private val SplitColors = listOf(
    Color(0xFF4F8DFF),
    Color(0xFF57C888),
    Color(0xFFE8A33D),
    Color(0xFFB07CD8),
    Color(0xFF5E9BD6),
    Color(0xFF8B93A1),
)

/** The pane under the tabs: Visits, History or Details. */
@Composable
internal fun ProfilePanes(
    tab: Int,
    profile: PlateProfileState,
    visit: PlateVisit?,
    cameraNames: Map<String, String>,
    mediaUrls: MediaUrls,
    isAdmin: Boolean,
    watchEntry: PlateWatchlistEntry?,
    statsTz: String,
    actions: PlateProfileActions,
    modifier: Modifier = Modifier,
) {
    Box(modifier.fillMaxWidth()) {
        when (tab) {
            0 -> VisitsPane(profile, visit, cameraNames, mediaUrls, actions)
            1 -> HistoryPane(profile, cameraNames, statsTz)
            else -> DetailsPane(profile, cameraNames, isAdmin, watchEntry, actions)
        }
    }
}

// ─── Visits ─────────────────────────────────────────────────────────────────

private sealed interface VisitItem {
    data class Header(val label: String) : VisitItem
    data class Row(val visit: PlateVisit) : VisitItem
}

@Composable
private fun VisitsPane(
    profile: PlateProfileState,
    current: PlateVisit?,
    cameraNames: Map<String, String>,
    mediaUrls: MediaUrls,
    actions: PlateProfileActions,
) {
    when {
        profile.loading && profile.visits.isEmpty() ->
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = LprAccent, modifier = Modifier.size(28.dp))
            }
        profile.error != null && profile.visits.isEmpty() ->
            PaneMessage("Couldn't load visits: ${profile.error}")
        profile.visits.isEmpty() -> PaneMessage("No reads of this plate in your cameras.")
        else -> {
            val now = remember(profile.visits) { System.currentTimeMillis() }
            val items = remember(profile.visits) {
                buildList {
                    var day: java.time.LocalDate? = null
                    profile.visits.forEach { v ->
                        val d = dayKey(v.startMs)
                        if (d != day) {
                            day = d
                            add(VisitItem.Header(dayLabel(v.startMs, now)))
                        }
                        add(VisitItem.Row(v))
                    }
                }
            }
            val totalReads = profile.visits.sumOf { it.count }
            LazyColumn(Modifier.fillMaxSize()) {
                items(items) { item ->
                    when (item) {
                        is VisitItem.Header -> PlateDayHeader(item.label)
                        is VisitItem.Row -> VisitRow(
                            visit = item.visit,
                            selected = item.visit.id == current?.id,
                            cameraName = cameraNames[item.visit.cameraId] ?: "Unknown camera",
                            mediaUrls = mediaUrls,
                            onClick = { actions.onSelectVisit(item.visit.best) },
                        )
                    }
                }
                item {
                    Text(
                        buildString {
                            append("${profile.visits.size} ${if (profile.visits.size == 1) "visit" else "visits"}")
                            if (totalReads >= 200) append(" from the latest 200 reads")
                        },
                        color = TextSecondary,
                        fontSize = 12.5.sp,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun VisitRow(
    visit: PlateVisit,
    selected: Boolean,
    cameraName: String,
    mediaUrls: MediaUrls,
    onClick: () -> Unit,
) {
    val best = visit.best
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 60.dp)
            .background(if (selected) LprAccentChip else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PlateCropImage(best, mediaUrls, slotW = 88.dp, slotH = 48.dp)
        Column(Modifier.weight(1f)) {
            Text(
                "${clockLabel(visit.startMs)}  ·  $cameraName",
                color = TextPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                buildString {
                    best.confidence?.let { append("${(it * 100).toInt()}%  ·  ") }
                    if (visit.count > 1) append("${visit.count} reads  ·  ")
                    append(if (selected) "Playing above" else "Tap to play")
                },
                color = TextSecondary,
                fontSize = 12.5.sp,
                maxLines = 1,
            )
        }
        Icon(
            Icons.Filled.PlayCircleOutline,
            contentDescription = null,
            tint = if (selected) LprAccentHot else TextSecondary,
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
private fun PaneMessage(text: String) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(text, color = TextSecondary, fontSize = 14.sp)
    }
}

// ─── History ────────────────────────────────────────────────────────────────

private fun zoneFor(tz: String): ZoneId = runCatching { ZoneId.of(tz) }.getOrDefault(Time.zone)

@Composable
private fun HistoryPane(profile: PlateProfileState, cameraNames: Map<String, String>, statsTz: String) {
    val stats = profile.stats
    if (stats == null) {
        PaneMessage(if (profile.loading) "Loading history..." else "History is not available from this server.")
        return
    }
    val readMs = remember(profile.selected.id) { Time.parseToMillis(profile.selected.ts) }
    val markHour = remember(readMs, statsTz) { Instant.ofEpochMilli(readMs).atZone(zoneFor(statsTz)).hour }
    val now = remember(stats) { System.currentTimeMillis() }
    val hours = remember(stats) { stats.hours.padTo(24) }
    val days = remember(stats) { stats.days30.padTo(30) }
    var hourSel by remember(profile.plate) { mutableStateOf<Int?>(null) }
    var daySel by remember(profile.plate) { mutableStateOf<Int?>(null) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
        ChartCard(title = hourChartTitle(stats.total), caption = hourSel?.let { hourBarCaption(it, hours[it], stats.total) } ?: "Tap a bar") {
            BarChart(
                values = hours,
                selected = hourSel,
                mark = markHour,
                onSelect = { hourSel = it },
                chartHeight = 76.dp,
                describe = { hourBarCaption(it, hours[it], stats.total) },
            )
            AxisRow(listOf("12 am", "6 am", "12 pm", "6 pm", "11 pm"))
            Text(
                "Each bar adds up that hour across every day the plate was seen. Amber: the hour of this read.",
                color = TextSecondary,
                fontSize = 11.5.sp,
                modifier = Modifier.padding(top = 6.dp),
            )
        }

        val slices = remember(stats) { cameraSplitSlices(stats.cameras, { cameraNames[it] ?: "Unknown camera" }) }
        if (slices.isNotEmpty()) {
            ChartCard(title = "Cameras", caption = null) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(top = 4.dp, bottom = 8.dp)
                        .height(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    slices.forEachIndexed { i, s ->
                        Box(
                            Modifier
                                .weight(s.n.coerceAtLeast(1).toFloat())
                                .fillMaxSize()
                                .background(SplitColors[i % SplitColors.size], RoundedCornerShape(3.dp)),
                        )
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    slices.forEachIndexed { i, s ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(9.dp).background(SplitColors[i % SplitColors.size], RoundedCornerShape(2.dp)))
                            Text(
                                "  ${s.n} ${s.label}",
                                color = Color(0xFFC7CBD3),
                                fontSize = 12.sp,
                            )
                        }
                    }
                }
            }
        }

        ChartCard(
            title = "Last 30 days",
            caption = daySel?.let { dayBarCaption(29 - it, days[it], now) } ?: "Tap a bar",
        ) {
            BarChart(
                values = days,
                selected = daySel,
                mark = null,
                onSelect = { daySel = it },
                chartHeight = 40.dp,
                describe = { dayBarCaption(29 - it, days[it], now) },
            )
            AxisRow(listOf("30 days ago", "Today"))
        }
    }
}

private fun List<Int>.padTo(n: Int): List<Int> = if (size >= n) take(n) else this + List(n - size) { 0 }

@Composable
private fun ChartCard(title: String, caption: String?, content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .background(CardColor, RoundedCornerShape(12.dp))
            .padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 10.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                title.uppercase(),
                color = TextSecondary,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.5.sp,
                modifier = Modifier.weight(1f),
            )
            if (caption != null) {
                // The tapped bar's number cross-fades in rather than snapping.
                Crossfade(targetState = caption, animationSpec = tween(200), label = "chart-caption") { text ->
                    Text(text, color = LprAccentHot, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                }
            }
        }
        Column(Modifier.padding(top = 6.dp)) { content() }
    }
}

@Composable
private fun AxisRow(labels: List<String>) {
    Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        labels.forEach { Text(it, color = TextSecondary, fontSize = 10.5.sp, maxLines = 1) }
    }
}

/**
 * Plain vertical bars. They grow in on first show; tapping one highlights it
 * (the rest dim) with a smooth colour change and reports its index so the card
 * can show the number. Tapping the same bar again clears it. [mark] draws a thin
 * amber line under one bar (the hour of the selected read).
 */
@Composable
private fun BarChart(
    values: List<Int>,
    selected: Int?,
    mark: Int?,
    onSelect: (Int?) -> Unit,
    chartHeight: Dp,
    describe: (Int) -> String,
) {
    val grow = remember { Animatable(0f) }
    LaunchedEffect(values) {
        grow.snapTo(0f)
        grow.animateTo(1f, tween(durationMillis = 550, easing = FastOutSlowInEasing))
    }
    val fractions = remember(values) { barFractions(values) }
    Row(
        Modifier.fillMaxWidth().height(chartHeight),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        values.indices.forEach { i ->
            val isSel = selected == i
            val color by animateColorAsState(
                targetValue = when {
                    isSel -> LprAccentHot
                    selected != null -> BarBase.copy(alpha = 0.45f)
                    else -> BarBase
                },
                animationSpec = tween(180),
                label = "bar-color",
            )
            val source = remember { MutableInteractionSource() }
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .semantics { contentDescription = describe(i) }
                    .clickable(interactionSource = source, indication = null, role = Role.Button) {
                        onSelect(if (isSel) null else i)
                    },
                contentAlignment = Alignment.BottomCenter,
            ) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(chartHeight * (fractions[i] * grow.value))
                        .background(color, RoundedCornerShape(topStart = 2.dp, topEnd = 2.dp)),
                )
                if (mark == i) {
                    Box(Modifier.fillMaxWidth().height(3.dp).background(LprWatchAmber))
                }
            }
        }
    }
}

// ─── Details ────────────────────────────────────────────────────────────────

@Composable
private fun DetailsPane(
    profile: PlateProfileState,
    cameraNames: Map<String, String>,
    isAdmin: Boolean,
    watchEntry: PlateWatchlistEntry?,
    actions: PlateProfileActions,
) {
    val now = remember(profile.stats) { System.currentTimeMillis() }
    val stats: PlateStatsDto? = profile.stats
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
        // Name
        DetailCard("Name") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val name = profile.displayName?.takeIf { it.isNotBlank() }
                Text(
                    name ?: "Unnamed plate",
                    color = if (name != null) TextPrimary else TextSecondary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (isAdmin && profile.plate.isNotBlank()) {
                    TextButton(onClick = actions.onRename) {
                        Text(if (name != null) "Rename" else "Name", color = LprAccentHot)
                    }
                }
            }
        }

        // Watchlist
        val watched = watchEntry != null && !watchEntry.isIgnore
        DetailCard("Watchlist") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    when {
                        watchEntry == null -> "Not on the watchlist"
                        watchEntry.isIgnore -> "Ignored. New reads are dropped."
                        watchEntry.notify -> "On the watchlist, alerts on sight"
                        else -> "On the watchlist, no alerts"
                    },
                    color = TextPrimary,
                    fontSize = 14.sp,
                    modifier = Modifier.weight(1f),
                )
                if (isAdmin) {
                    Switch(checked = watched, onCheckedChange = { actions.onToggleWatch() }, colors = lprSwitchColors())
                }
            }
        }

        // Known misreads
        DetailCard("Known misreads", caption = "counted as this plate") {
            if (profile.aliases.isEmpty()) {
                Text("No known misreads.", color = TextSecondary, fontSize = 13.5.sp)
            } else {
                profile.aliases.forEach { a -> MisreadRow(a, profile.plate, isAdmin) { actions.onUndoAlias(a.aliasPlate) } }
            }
            if (canOfferPlateCorrection(isAdmin, profile.plate)) {
                OutlinedButton(
                    onClick = actions.onCorrect,
                    modifier = Modifier.padding(top = 8.dp).height(36.dp),
                ) { Text("Correct plate", color = Color(0xFFE8E9ED), fontSize = 13.sp) }
            }
        }

        // Facts
        DetailCard("Details") {
            val region = profile.selected.region?.takeIf { it.isNotBlank() }
            Fact2("Region", region ?: "Unknown")
            if (stats != null) {
                stats.firstSeen?.let { Fact2("First seen", shortDateLabel(Time.parseToMillis(it), now)) }
                stats.lastSeen?.let { Fact2("Last seen", agoLabel(Time.parseToMillis(it), now)) }
                Fact2("Seen at", "${stats.cameras.size} ${if (stats.cameras.size == 1) "camera" else "cameras"}")
            }
        }

        val summary = remember(stats, cameraNames) {
            stats?.let {
                plateSummary(
                    stats = it,
                    cameraName = { id -> cameraNames[id] ?: "an unknown camera" },
                    nowMs = now,
                    firstSeenMs = it.firstSeen?.let(Time::parseToMillis),
                )
            }.orEmpty()
        }
        if (summary.isNotBlank()) {
            Text(
                summary,
                color = Color(0xFFC7CBD3),
                fontSize = 13.5.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            )
        }
    }
}

@Composable
private fun DetailCard(title: String, caption: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .background(CardColor, RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                title.uppercase(),
                color = TextSecondary,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.5.sp,
                modifier = Modifier.weight(1f),
            )
            if (caption != null) Text(caption, color = TextSecondary, fontSize = 12.sp)
        }
        content()
    }
}

@Composable
private fun Fact2(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Text(label, color = Color(0xFFC7CBD3), fontSize = 13.5.sp, modifier = Modifier.weight(1f))
        Text(value, color = TextPrimary, fontSize = 13.5.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun MisreadRow(alias: PlateAliasDto, plate: String, canUndo: Boolean, onUndo: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 40.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            alias.aliasPlate,
            color = Color(0xFFC7CBD3),
            fontFamily = JetBrainsMono,
            fontWeight = FontWeight.Bold,
            fontSize = 14.sp,
        )
        Text("counts as $plate", color = TextSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (canUndo) TextButton(onClick = onUndo) { Text("Undo", color = LprAccentHot, fontSize = 13.sp) }
    }
}
