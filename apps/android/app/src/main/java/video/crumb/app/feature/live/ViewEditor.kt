// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.zIndex
import video.crumb.app.data.CameraView
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextSecondary
import java.util.UUID

/** What the editor is opened for: a brand-new view, or editing an existing one. */
sealed interface ViewEditorTarget {
    object New : ViewEditorTarget
    data class Edit(val view: CameraView) : ViewEditorTarget
}

/** Fixed row height for the selected-camera rows — also the drag swap threshold. */
private val ROW_HEIGHT = 56.dp

/**
 * Full-screen editor for a local [CameraView]: name it, tap cameras from the
 * "Add cameras" list to include them, then drag the ⠿ handle to reorder. Built for
 * a phone — no grid/slot placement, just an ordered camera list.
 *
 * @param allCameras All available cameras as `(id, name)`, in wall order.
 * @param onSave Receives the finished view (new id minted for [ViewEditorTarget.New]).
 * @param onDelete Receives the view id to delete (only reachable when editing).
 * @param onDismiss Cancel without saving.
 */
@Composable
fun ViewEditorDialog(
    target: ViewEditorTarget,
    allCameras: List<Pair<String, String>>,
    onSave: (CameraView) -> Unit,
    onDelete: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val initial = (target as? ViewEditorTarget.Edit)?.view
    val viewId = remember { initial?.id ?: UUID.randomUUID().toString() }
    var name by remember { mutableStateOf(initial?.name ?: "") }
    // Ordered camera ids in the view; a SnapshotStateList so reorders recompose.
    val selected = remember { mutableStateListOf<String>().also { l -> initial?.cameraIds?.let(l::addAll) } }
    val nameById = remember(allCameras) { allCameras.toMap() }
    val available = allCameras.filter { it.first !in selected }

    // Shared drag state for the reorderable list (hoisted so every row can read it).
    var dragId by remember { mutableStateOf<String?>(null) }
    var dragAccum by remember { mutableFloatStateOf(0f) }
    val rowPx = with(LocalDensity.current) { ROW_HEIGHT.toPx() }

    // If the row being dragged is removed (e.g. its ✕, or a multi-touch remove of the
    // dragged camera), its gesture never reports onDragEnd — so defensively clear the
    // drag highlight whenever the selection's membership changes (size-keyed so a pure
    // reorder, which keeps size, doesn't reset an in-progress drag).
    LaunchedEffect(selected.size) {
        if (dragId != null && dragId !in selected) {
            dragId = null
            dragAccum = 0f
        }
    }

    fun swap(i: Int, j: Int) {
        if (i in selected.indices && j in selected.indices) {
            val t = selected[i]; selected[i] = selected[j]; selected[j] = t
        }
    }

    val canSave = name.isNotBlank() && selected.isNotEmpty()

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = NavyDeep) {
            Column(Modifier.fillMaxSize()) {
                // ── top bar ───────────────────────────────────────────────────
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(NavySurface)
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    HintTooltip("Cancel") {
                        IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Cancel") }
                    }
                    Text(
                        text = if (initial == null) "New view" else "Edit view",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f).padding(start = 4.dp),
                    )
                    TextButton(
                        onClick = { onSave(CameraView(viewId, name.trim(), selected.toList())) },
                        enabled = canSave,
                    ) {
                        Text("Save", color = if (canSave) TealAccent else TextSecondary)
                    }
                }

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .verticalScroll(rememberScrollState())
                        .padding(12.dp),
                ) {
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it },
                        label = { Text("View name") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )

                    // ── available cameras (tap to add) — TOP ──────────────────
                    Spacer(Modifier.height(16.dp))
                    Text("Add cameras", style = MaterialTheme.typography.labelLarge, color = TextSecondary)
                    Spacer(Modifier.height(4.dp))
                    if (available.isEmpty()) {
                        Text(
                            "All cameras are in this view.",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                            modifier = Modifier.padding(vertical = 8.dp),
                        )
                    } else {
                        available.forEach { (id, nm) ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(ROW_HEIGHT)
                                    .clickable { selected.add(id) }
                                    .padding(horizontal = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(Icons.Default.Add, contentDescription = "Add", tint = TealAccent)
                                Spacer(Modifier.width(12.dp))
                                Text(nm, style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }

                    // ── selected cameras (reorderable) — BOTTOM ───────────────
                    Spacer(Modifier.height(16.dp))
                    Box1pxDivider()
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "In this view — long-press the handle to reorder (${selected.size})",
                        style = MaterialTheme.typography.labelLarge,
                        color = TextSecondary,
                    )
                    Spacer(Modifier.height(4.dp))
                    if (selected.isEmpty()) {
                        Text(
                            "Tap cameras above to add them.",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                            modifier = Modifier.padding(vertical = 8.dp),
                        )
                    } else {
                        // key(camId) keeps each row's composable (and its drag gesture)
                        // alive across reorders, so an in-progress drag isn't restarted.
                        selected.forEach { camId ->
                            key(camId) {
                                val dragging = dragId == camId
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(ROW_HEIGHT)
                                        .zIndex(if (dragging) 1f else 0f)
                                        .graphicsLayer { translationY = if (dragging) dragAccum else 0f }
                                        .background(
                                            if (dragging) NavySurface else NavyDeep,
                                            RoundedCornerShape(6.dp),
                                        )
                                        .padding(horizontal = 4.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.DragHandle,
                                        contentDescription = "Reorder",
                                        tint = TextSecondary,
                                        modifier = Modifier.pointerInput(camId) {
                                            // Long-press to start: a deliberate press on the
                                            // handle claims the pointer so the parent
                                            // verticalScroll can't steal the (vertical) drag.
                                            detectDragGesturesAfterLongPress(
                                                onDragStart = { dragId = camId; dragAccum = 0f },
                                                onDragEnd = { dragId = null; dragAccum = 0f },
                                                onDragCancel = { dragId = null; dragAccum = 0f },
                                                onDrag = { change, amount ->
                                                    change.consume()
                                                    dragAccum += amount.y
                                                    var idx = selected.indexOf(camId)
                                                    if (idx >= 0) {
                                                        while (dragAccum > rowPx / 2 && idx < selected.lastIndex) {
                                                            swap(idx, idx + 1); idx++; dragAccum -= rowPx
                                                        }
                                                        while (dragAccum < -rowPx / 2 && idx > 0) {
                                                            swap(idx, idx - 1); idx--; dragAccum += rowPx
                                                        }
                                                    }
                                                },
                                            )
                                        },
                                    )
                                    Spacer(Modifier.width(12.dp))
                                    Text(
                                        text = nameById[camId] ?: "(removed camera)",
                                        style = MaterialTheme.typography.bodyMedium,
                                        modifier = Modifier.weight(1f),
                                    )
                                    HintTooltip("Remove from view") {
                                        IconButton(onClick = { selected.remove(camId) }) {
                                            Icon(Icons.Default.Close, contentDescription = "Remove", tint = TextSecondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (initial != null) {
                        Spacer(Modifier.height(24.dp))
                        TextButton(onClick = { onDelete(initial.id) }) {
                            Icon(Icons.Default.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                            Spacer(Modifier.width(6.dp))
                            Text("Delete view", color = MaterialTheme.colorScheme.error)
                        }
                    }
                    Spacer(Modifier.height(40.dp))
                }
            }
        }
    }
}

/** A thin horizontal rule (avoids Divider/HorizontalDivider API-name churn). */
@Composable
private fun Box1pxDivider() {
    Row(
        Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(NavySurface),
        horizontalArrangement = Arrangement.Center,
    ) {}
}

/**
 * Views manager — the list-level utility reached from the Live overflow → "Manage
 * views" (N5). Lists every saved [CameraView] with:
 *   - tap a row to SELECT (activate) that view on the wall,
 *   - ▲ / ▼ to REORDER (persisted so the chip bar reflects the new order),
 *   - ✎ to edit a view (opens [ViewEditorDialog] via [onEdit]),
 *   - ＋ New view at the top.
 *
 * Up/down move buttons are used rather than drag-to-reorder here because the row
 * already has multiple tap targets (select / edit); discrete arrows are
 * unambiguous and keep reorder + selection from fighting over the same gesture.
 *
 * @param views Current saved views, in display order.
 * @param activeViewId The currently-active view id (highlighted), or null for "All".
 * @param onReorder Move the view at index `from` to index `to` (caller persists).
 * @param onSelect Activate the view with this id (null = "All cameras").
 * @param onNew Open the editor for a brand-new view.
 * @param onEdit Open the editor for an existing view.
 * @param onDismiss Close the manager.
 */
@Composable
fun ViewsManagerDialog(
    views: List<CameraView>,
    activeViewId: String?,
    onReorder: (Int, Int) -> Unit,
    onSelect: (String?) -> Unit,
    onNew: () -> Unit,
    onEdit: (CameraView) -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = NavyDeep) {
            Column(Modifier.fillMaxSize()) {
                // ── top bar ───────────────────────────────────────────────────
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(NavySurface)
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    HintTooltip("Close") {
                        IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close") }
                    }
                    Text(
                        text = "Manage views",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f).padding(start = 4.dp),
                    )
                    TextButton(onClick = onNew) {
                        Icon(Icons.Default.Add, contentDescription = null, tint = TealAccent)
                        Spacer(Modifier.width(4.dp))
                        Text("New", color = TealAccent)
                    }
                }

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .verticalScroll(rememberScrollState())
                        .padding(12.dp),
                ) {
                    // "All cameras" pseudo-row (always first; selectable, not movable).
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(ROW_HEIGHT)
                            .clickable { onSelect(null) }
                            .background(
                                if (activeViewId == null) NavySurface else NavyDeep,
                                RoundedCornerShape(6.dp),
                            )
                            .padding(horizontal = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "All cameras",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                        )
                        if (activeViewId == null) {
                            Text("Active", style = MaterialTheme.typography.labelSmall, color = TealAccent)
                        }
                    }

                    Spacer(Modifier.height(8.dp))
                    if (views.isEmpty()) {
                        Text(
                            "No saved views yet. Tap “New” to create one.",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                            modifier = Modifier.padding(vertical = 8.dp),
                        )
                    } else {
                        Text(
                            "Tap to activate · use the arrows to reorder",
                            style = MaterialTheme.typography.labelLarge,
                            color = TextSecondary,
                        )
                        Spacer(Modifier.height(4.dp))
                        views.forEachIndexed { index, v ->
                            val isActive = v.id == activeViewId
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(ROW_HEIGHT)
                                    .clickable { onSelect(v.id) }
                                    .background(
                                        if (isActive) NavySurface else NavyDeep,
                                        RoundedCornerShape(6.dp),
                                    )
                                    .padding(horizontal = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = v.name,
                                        style = MaterialTheme.typography.bodyMedium,
                                    )
                                    Text(
                                        text = "${v.cameraIds.size} cameras",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = TextSecondary,
                                    )
                                }
                                // Move up
                                HintTooltip("Move up") {
                                    IconButton(
                                        onClick = { onReorder(index, index - 1) },
                                        enabled = index > 0,
                                    ) {
                                        Icon(
                                            Icons.Default.KeyboardArrowUp,
                                            contentDescription = "Move up",
                                            tint = if (index > 0) TextSecondary else TextSecondary.copy(alpha = 0.3f),
                                        )
                                    }
                                }
                                // Move down
                                HintTooltip("Move down") {
                                    IconButton(
                                        onClick = { onReorder(index, index + 1) },
                                        enabled = index < views.lastIndex,
                                    ) {
                                        Icon(
                                            Icons.Default.KeyboardArrowDown,
                                            contentDescription = "Move down",
                                            tint = if (index < views.lastIndex) TextSecondary else TextSecondary.copy(alpha = 0.3f),
                                        )
                                    }
                                }
                                // Edit
                                HintTooltip("Edit view") {
                                    IconButton(onClick = { onEdit(v) }) {
                                        Icon(Icons.Default.Edit, contentDescription = "Edit view", tint = TealAccent)
                                    }
                                }
                            }
                            Spacer(Modifier.height(4.dp))
                        }
                    }
                    Spacer(Modifier.height(40.dp))
                }
            }
        }
    }
}
