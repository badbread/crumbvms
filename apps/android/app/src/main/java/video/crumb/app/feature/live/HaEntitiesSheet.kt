// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import video.crumb.app.data.HaControlDescriptor
import video.crumb.app.data.HaLinkDto
import video.crumb.app.data.HaStatesResponse
import video.crumb.app.data.controlActions
import video.crumb.app.data.showsSlider
import java.time.Duration
import java.time.Instant
import java.time.OffsetDateTime
import kotlin.math.roundToInt

// Home Assistant default (dark) theme tokens — the sheet renders in HA's own
// look regardless of the app theme, so it feels like an extension of the HA app.
private val HaBg = Color(0xFF111111)
private val HaCard = Color(0xFF1C1C1C)
private val HaCardActive = Color(0xFF232323)
private val HaPrimaryText = Color(0xFFE1E1E1)
private val HaSecondaryText = Color(0xFF9B9B9B)
private val HaDivider = Color(0x1FE1E1E1)
private val HaBlue = Color(0xFF18BCF2) // HA brand mark / primary action accent
private val HaAmber = Color(0xFFFFC107) // cover Close accent
private val HaRed = Color(0xFFF44336) // lock Unlock accent
private val HaGrey = Color(0xFF7A7A7A) // neutral Stop / Cancel accent

// The entity look (icon + state color + label) comes from the ONE canonical
// mapping in `HaVisual.kt` (`badgeVisual`), shared with the on-video badge
// overlay so an entity reads identically in the badge and in this sheet (#437).
// The HaAmber/HaRed/HaGrey tokens above are the actuator control-row button
// accents (#428) — the state-color derivation itself lives in `HaVisual.kt`.

/** "Changed N ago" from an RFC3339 timestamp, HA-style. */
private fun changedAgo(iso: String?): String? {
    if (iso.isNullOrBlank()) return null
    val then = runCatching { OffsetDateTime.parse(iso).toInstant() }
        .getOrElse { runCatching { Instant.parse(iso) }.getOrNull() } ?: return null
    val d = Duration.between(then, Instant.now())
    val secs = d.seconds.coerceAtLeast(0)
    val label = when {
        secs < 45 -> "just now"
        secs < 3600 -> "${(secs / 60).coerceAtLeast(1)} min ago"
        secs < 86_400 -> "${secs / 3600} hr ago"
        else -> "${secs / 86_400} day${if (secs / 86_400 == 1L) "" else "s"} ago"
    }
    return if (label == "just now") "Changed just now" else "Changed $label"
}

/**
 * The Home Assistant entity sheet for one camera. Shows the camera's linked HA
 * entities as HA-style tile cards with live state; tapping a tile opens an HA
 * "more-info"-style detail. Phase 2 (#187): when [canActuate] and the link is an
 * actuator, that detail also carries controls (with a confirm on cover/lock);
 * every other case stays read-only. Actuator links whose current state carries a
 * `control` descriptor (#442, Slice 1: a dimmable light, a positionable cover, a
 * speed-controllable fan) also get a value slider alongside the action pills.
 * [onAction] fires one service call for a link — [value] is non-null only for a
 * value action (a slider commit); [inFlightLinkIds] holds the
 * [HaLinkDto.actionLinkId]s currently posting.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HaEntitiesSheet(
    cameraName: String,
    links: List<HaLinkDto>,
    states: HaStatesResponse?,
    onDismiss: () -> Unit,
    canActuate: Boolean = false,
    inFlightLinkIds: Set<String> = emptySet(),
    onAction: (HaLinkDto, String, Double?) -> Unit = { _, _, _ -> },
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selected by remember { mutableStateOf<HaLinkDto?>(null) }
    val sorted = remember(links) { links.sortedBy { it.sortOrder } }
    // Grey the icon honestly when HA is unreachable, exactly as the badge does.
    val stale = states?.stale == true

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = HaBg,
        dragHandle = { HaGrabber() },
    ) {
        // Header
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 16.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Home, contentDescription = null, tint = HaBlue, modifier = Modifier.size(26.dp))
            Spacer(Modifier.size(10.dp))
            Column {
                Text("Home Assistant", color = HaPrimaryText, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                Text(
                    "$cameraName · ${sorted.size} " + if (sorted.size == 1) "entity" else "entities",
                    color = HaSecondaryText,
                    fontSize = 12.5.sp,
                )
            }
        }
        if (states?.stale == true) {
            Text(
                "Home Assistant unreachable — showing last known state",
                color = HaSecondaryText,
                fontSize = 12.sp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 2.dp),
            )
        }

        LazyColumn(
            contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 28.dp, top = 2.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(sorted, key = { it.id }) { link ->
                val st = states?.stateFor(link.entityId)
                HaTile(link, st?.state, st?.unit, stale, onClick = { selected = link })
            }
        }
    }

    selected?.let { link ->
        val st = states?.stateFor(link.entityId)
        HaMoreInfoDialog(
            link, st?.state, st?.lastChanged, stale,
            unit = st?.unit,
            control = st?.control,
            canActuate = canActuate && link.isActuator,
            inFlight = link.actionLinkId in inFlightLinkIds,
            onAction = { action, value -> onAction(link, action, value) },
            onDismiss = { selected = null },
        )
    }
}

@Composable
private fun HaGrabber() {
    Box(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 8.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 36.dp, height = 4.dp).background(Color(0xFF3A3A3A), CircleShape))
    }
}

/** One HA tile card: state-colored icon in a tinted circle, name + state. */
@Composable
private fun HaTile(link: HaLinkDto, state: String?, unit: String?, stale: Boolean, onClick: () -> Unit) {
    val v = badgeVisual(link, state, stale)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(HaCard)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(CircleShape).background(v.color.copy(alpha = 0.16f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(v.icon, contentDescription = null, tint = v.color, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                link.displayName,
                color = HaPrimaryText,
                fontSize = 14.5.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
            )
            Text(haStateDisplay(v, state, unit), color = v.color, fontSize = 13.sp)
        }
        Text("›", color = Color(0xFF4C4C4C), fontSize = 20.sp)
    }
}

/**
 * HA "more-info"-style detail dialog. Read-only by default (also opened by
 * long-pressing an on-video badge in [HaBadgeOverlayLayer], or tapping a
 * non-controllable one). When [canActuate] is true and the link is an actuator it
 * grows a control row: a single primary action for simple domains (fired
 * directly), and confirm-guarded multi-action buttons for `cover`/`lock`. When
 * [control] is also present (a dimmable light, a positionable cover, a
 * speed-controllable fan — #442, Slice 1) it additionally grows a value slider
 * beneath the control row, gated the same way (`allowed_actions`, migration
 * 0075).
 */
@Composable
internal fun HaMoreInfoDialog(
    link: HaLinkDto,
    state: String?,
    lastChanged: String?,
    stale: Boolean,
    onDismiss: () -> Unit,
    unit: String? = null,
    control: HaControlDescriptor? = null,
    canActuate: Boolean = false,
    inFlight: Boolean = false,
    // [value] is non-null only when this call is a slider commit (a value
    // action); every discrete action call passes null.
    onAction: (String, Double?) -> Unit = { _, _ -> },
) {
    val v = badgeVisual(link, state, stale)
    // Pending confirm-guarded discrete action (action verb -> human prompt),
    // for cover/lock. The slider owns its own confirm state (it also needs to
    // revert the thumb on cancel) — see [HaValueSlider].
    var pendingConfirm by remember { mutableStateOf<Pair<String, String>?>(null) }
    val showControls = canActuate && link.isActuator
    val needsConfirm = haNeedsConfirm(link)

    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(HaCard)
                .padding(horizontal = 20.dp, vertical = 22.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                modifier = Modifier.size(76.dp).clip(CircleShape).background(v.color.copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(v.icon, contentDescription = null, tint = v.color, modifier = Modifier.size(40.dp))
            }
            Spacer(Modifier.height(12.dp))
            Text(link.displayName, color = HaPrimaryText, fontSize = 19.sp, fontWeight = FontWeight.Medium)
            Text(haStateDisplay(v, state, unit), color = v.color, fontSize = 15.sp)
            changedAgo(lastChanged)?.let {
                Spacer(Modifier.height(4.dp))
                Text(it, color = HaSecondaryText, fontSize = 12.5.sp)
            }

            if (showControls) {
                Spacer(Modifier.height(18.dp))
                HaControlRow(
                    link = link,
                    inFlight = inFlight,
                    needsConfirm = needsConfirm,
                    // Simple domains fire directly; cover/lock (and any link with
                    // require_confirm, migration 0075) route through the confirm
                    // prompt (physical-security guard).
                    onFire = { action -> onAction(action, null) },
                    onConfirm = { action, prompt -> pendingConfirm = action to prompt },
                    entityName = link.displayName,
                )
                // The slider stays MOUNTED across the in-flight window — it is NOT
                // gated on `!inFlight`. Unmounting it on every commit destroyed its
                // committed-hold state (#465) and collapsed then re-expanded the
                // dialog: the residual "bar + window bounce". It holds the committed
                // value itself until the poll converges. `control != null` re-stated
                // (on top of `showsSlider`'s own check) so the compiler smart-casts
                // `control` to non-null below.
                if (control != null && link.showsSlider(control)) {
                    HaValueSlider(
                        link = link,
                        control = control,
                        entityName = link.displayName,
                        needsConfirm = needsConfirm,
                        onFire = { value -> onAction(control.action, value) },
                    )
                }
            }

            Spacer(Modifier.height(16.dp))
            HaAttrRow("Device class", link.deviceClass?.replace('_', ' ') ?: "—")
            HaAttrRow("Entity", link.entityId)
        }
    }

    pendingConfirm?.let { (action, prompt) ->
        HaConfirmDialog(
            prompt = prompt,
            onConfirm = {
                pendingConfirm = null
                onAction(action, null)
            },
            onCancel = { pendingConfirm = null },
        )
    }
}

/**
 * Whether [link]'s controls (discrete actions AND the value slider) must
 * confirm before firing: the link's own `require_confirm` (migration 0075), or
 * a physical-security domain (`cover`/`lock`) regardless of that flag. Shared
 * by [HaControlRow] and [HaValueSlider] so a cover's Open/Close pills and its
 * position slider confirm identically.
 */
private fun haNeedsConfirm(link: HaLinkDto): Boolean =
    link.requireConfirm || link.domain == "cover" || link.domain == "lock"

/**
 * The control row for an actuator detail. The button set is derived from the
 * link's [HaLinkDto.controlActions] (migration 0075): today's default single
 * primary for simple domains, Open/Stop/Close for `cover`, Lock/Unlock for
 * `lock`, or exactly the permitted subset when the link restricts
 * `allowed_actions`. A button routes through [onConfirm] (a prompt) when the
 * link requires a confirm or the domain is a physical-security one (cover/lock),
 * else fires directly via [onFire]. While [inFlight], buttons are replaced by a
 * spinner.
 */
@Composable
private fun HaControlRow(
    link: HaLinkDto,
    inFlight: Boolean,
    entityName: String,
    needsConfirm: Boolean,
    onFire: (String) -> Unit,
    onConfirm: (String, String) -> Unit,
) {
    // Reserve a stable height whether we're showing the action pills or the
    // in-flight spinner, so toggling `inFlight` on a commit never re-measures and
    // re-centers the dialog — half of the "window bounce" (#442 Slice 1 residual).
    // The pill row is ~40dp tall (10dp*2 padding + text); 44dp holds both.
    Box(
        modifier = Modifier.fillMaxWidth().height(44.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (inFlight) {
            androidx.compose.material3.CircularProgressIndicator(
                modifier = Modifier.size(26.dp),
                color = HaBlue,
                strokeWidth = 2.5.dp,
            )
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (action in link.controlActions()) {
                    HaActionButton(action.label, haActionAccent(action.verb)) {
                        if (needsConfirm) {
                            onConfirm(action.verb, "${action.label} $entityName?")
                        } else {
                            onFire(action.verb)
                        }
                    }
                }
            }
        }
    }
}

/**
 * The value slider for a link's current [HaControlDescriptor] (#442, Slice 1):
 * a dimmable light's brightness, a cover's position, a fan's speed. Drives
 * [min]/[max]/[step] straight from the descriptor — never hardcoded 0..100 —
 * so a future non-percent kind (Slice 2 temperature) renders correctly with no
 * client change.
 *
 * Tracks the drag locally (a Float `sliderValue`, the Slider's native type, so a
 * gesture never round-trips through Double) and re-syncs to the server-reported
 * [HaControlDescriptor.value] whenever it changes AND the user is not mid-drag,
 * mid-confirm, nor holding a just-committed value, so the `/ha/states` poll
 * converges the thumb exactly like the action buttons/badge — never an optimistic
 * local flip on commit. The Slider is CONTINUOUS (no discrete `steps`, which snap
 * the thumb and read as a bounce); the released value is snapped to `step` in
 * [haSnapToStep]. Commits on release ([Slider]'s `onValueChangeFinished`): exactly
 * ONE call per gesture, never continuously mid-drag. When [needsConfirm] (the link's own
 * `require_confirm`, or a physical-security domain — same gate as
 * [HaControlRow]), the release opens a confirm prompt with the target value
 * baked in instead of firing immediately; cancelling reverts the thumb.
 */
@Composable
private fun HaValueSlider(
    link: HaLinkDto,
    control: HaControlDescriptor,
    entityName: String,
    needsConfirm: Boolean,
    onFire: (Double) -> Unit,
) {
    var dragging by remember(link.actionLinkId) { mutableStateOf(false) }
    // A value awaiting the user's confirm (cover / lock / require_confirm); non-null
    // only while its confirm dialog is up.
    var awaitingConfirm by remember(link.actionLinkId) { mutableStateOf<Double?>(null) }
    // A value we just committed and hold the thumb at until the /ha/states poll
    // reflects it. Without this hold the poll -- which for a beat still reports the
    // device's OLD value while it transitions -- snaps the thumb back the instant
    // you release, then jumps it to the committed value a poll later (the bounce,
    // issue #465).
    var committed by remember(link.actionLinkId) { mutableStateOf<Double?>(null) }
    // The thumb's live position, kept in Float (the Slider's native type) so a
    // drag never round-trips Double<->Float and quantizes mid-gesture. Seeded from
    // the server value; the idle effect below re-syncs it to the poll.
    var sliderValue by remember(link.actionLinkId) { mutableFloatStateOf(control.value.toFloat()) }

    val step = control.step.takeIf { it > 0.0 } ?: 1.0

    // Track the live poll ONLY when the user is neither dragging, holding a
    // just-committed value, nor waiting on a confirm. Release the hold once the
    // poll converges to within a step of the committed value (absorbs
    // percent<->brightness rounding), or when the safety timeout below clears it.
    LaunchedEffect(control.value, committed) {
        if (dragging || awaitingConfirm != null) return@LaunchedEffect
        val c = committed
        if (c != null && haHoldConverged(control.value, c, step)) {
            committed = null
        }
        if (committed == null) sliderValue = control.value.toFloat()
    }
    // Never hold forever: a dropped request or a device that never reaches the
    // target would otherwise freeze the thumb. Drop the hold after a short window
    // so it resumes tracking the real state.
    LaunchedEffect(committed) {
        if (committed != null) {
            kotlinx.coroutines.delay(6000)
            committed = null
        }
    }

    fun commit(target: Double) {
        sliderValue = target.toFloat()
        committed = target
        onFire(target)
    }

    val label = haValueLabel(control.action)
    val unitSuffix = control.unit ?: if (control.kind == "percent") "%" else ""
    val minF = control.min.toFloat()
    val maxF = control.max.toFloat()

    Column(Modifier.fillMaxWidth().padding(top = 14.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, color = HaSecondaryText, fontSize = 13.sp)
            Text(
                "${sliderValue.roundToInt()}$unitSuffix",
                color = HaPrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        // CONTINUOUS slider (no `steps`): a discrete slider snaps the thumb to tick
        // positions, which combined with recomposition read as a "bar bounce". The
        // thumb tracks the finger exactly; we snap to `step` only on release, in
        // [haSnapToStep], so the POSTed value stays grid-aligned.
        Slider(
            value = sliderValue.coerceIn(minF, maxF),
            onValueChange = { dragging = true; sliderValue = it },
            onValueChangeFinished = {
                dragging = false
                val target = haSnapToStep(sliderValue.toDouble(), control.min, control.max, step)
                if (needsConfirm) awaitingConfirm = target else commit(target)
            },
            valueRange = minF..maxF,
            colors = SliderDefaults.colors(
                thumbColor = HaBlue,
                activeTrackColor = HaBlue,
                inactiveTrackColor = HaDivider,
            ),
        )
    }

    awaitingConfirm?.let { target ->
        HaConfirmDialog(
            prompt = "Set $label for $entityName to ${target.roundToInt()}$unitSuffix?",
            onConfirm = {
                awaitingConfirm = null
                commit(target)
            },
            onCancel = {
                awaitingConfirm = null
                sliderValue = control.value.toFloat()
            },
        )
    }
}

/**
 * Snap a raw slider value onto the descriptor's grid: clamp to [min]..[max], then
 * round to the nearest whole [step] measured from [min]. Kind-agnostic (never a
 * hardcoded 0..100). Applied ONCE on release so the drag itself stays smooth (the
 * Slider is continuous) while the committed/POSTed value is step-aligned.
 */
internal fun haSnapToStep(raw: Double, min: Double, max: Double, step: Double): Double {
    val s = step.takeIf { it > 0.0 } ?: 1.0
    val clamped = raw.coerceIn(min, max)
    val snapped = min + ((clamped - min) / s).roundToInt() * s
    return snapped.coerceIn(min, max)
}

/**
 * Whether the just-committed [committed] value has been reflected by the poll:
 * true once the polled [value] is within a step (plus a small margin, to absorb
 * percent<->brightness rounding) of it. While false the slider keeps holding the
 * committed value rather than snapping to the device's transitioning old value
 * (#465). Pure, so it's unit-tested.
 */
internal fun haHoldConverged(value: Double, committed: Double, step: Double): Boolean =
    kotlin.math.abs(value - committed) <= step + 0.5

/**
 * Human label for a value action word — shown above the slider only (the
 * discrete action pills read fine raw, see `HA_ACTION_LABELS` in admin.html
 * for the same words with a "Set " prefix suited to a checkbox list).
 */
private fun haValueLabel(action: String): String = when (action) {
    "set_brightness" -> "Brightness"
    "set_position" -> "Position"
    "set_speed" -> "Speed"
    else -> action.removePrefix("set_").replaceFirstChar { it.uppercaseChar() }
}

/** Accent color for a control button, preserving the cover/lock/simple palette. */
private fun haActionAccent(verb: String): Color = when (verb) {
    "turn_off", "close_cover" -> HaAmber
    "unlock" -> HaRed
    "stop_cover" -> HaGrey
    else -> HaBlue // turn_on, toggle, open_cover, lock, press
}

/** A rounded pill action button in the HA sheet's dark theme. */
@Composable
private fun HaActionButton(label: String, accent: Color, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(accent.copy(alpha = 0.18f))
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Confirmation prompt shown before any cover/lock action fires (#428). */
@Composable
private fun HaConfirmDialog(prompt: String, onConfirm: () -> Unit, onCancel: () -> Unit) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onCancel) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(HaCard)
                .padding(horizontal = 22.dp, vertical = 22.dp),
        ) {
            Text(prompt, color = HaPrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(20.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                HaActionButton("Cancel", HaGrey, onClick = onCancel)
                Spacer(Modifier.size(10.dp))
                HaActionButton("Confirm", HaBlue, onClick = onConfirm)
            }
        }
    }
}

@Composable
private fun HaAttrRow(key: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(key, color = HaSecondaryText, fontSize = 13.5.sp)
        Text(value, color = HaPrimaryText, fontSize = 13.5.sp)
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(HaDivider))
}
