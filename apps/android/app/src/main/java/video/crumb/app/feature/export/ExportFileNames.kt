// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.export

import video.crumb.app.data.ExportOutputFile

/**
 * Containers the server can actually produce for an export: `mp4` and `mkv`
 * single files, and the `zip` archive (`services/api/src/export.rs`). `mov` is
 * tolerated for forward compatibility. Anything else the server reports is
 * treated as untrusted and falls back to [DEFAULT_EXPORT_EXTENSION].
 */
internal val ALLOWED_EXPORT_EXTENSIONS = setOf("mp4", "mkv", "zip", "mov")

internal const val DEFAULT_EXPORT_EXTENSION = "mp4"

private const val MAX_BASE_NAME_LENGTH = 120

/** Characters never allowed in a saved file name (path separators, reserved, control). */
private val UNSAFE_NAME_CHARS = Regex("[\\u0000-\\u001f\\u007f/\\\\:*?\"<>|]")

/**
 * Extension (no dot, lowercase) of a server-supplied file name, or
 * [DEFAULT_EXPORT_EXTENSION] unless it is in [ALLOWED_EXPORT_EXTENSIONS]. The
 * name comes from the server, so it is never trusted to build a path from.
 */
internal fun sanitizedExportExtension(serverName: String): String {
    val dot = serverName.lastIndexOf('.')
    if (dot < 0 || dot == serverName.length - 1) return DEFAULT_EXPORT_EXTENSION
    val ext = serverName.substring(dot + 1).lowercase()
    return if (ext in ALLOWED_EXPORT_EXTENSIONS) ext else DEFAULT_EXPORT_EXTENSION
}

/**
 * Reduce a server-supplied display name to a safe base name (no extension):
 * only the last path component survives, reserved and control characters are
 * replaced, any `..` run is collapsed, and leading/trailing dots and spaces are
 * trimmed. Returns null when nothing usable is left.
 */
internal fun sanitizedExportBaseName(serverName: String): String? {
    val lastComponent = serverName.substringAfterLast('/').substringAfterLast('\\')
    val withoutExt = lastComponent.substringBeforeLast('.', lastComponent)
    val cleaned = withoutExt
        .replace(UNSAFE_NAME_CHARS, "_")
        .replace(Regex("\\.{2,}"), ".")
        .trim { it == '.' || it == ' ' }
        .take(MAX_BASE_NAME_LENGTH)
        .trim { it == '.' || it == ' ' }
    return cleaned.ifEmpty { null }
}

/**
 * Safe file name (with allow-listed extension) to save [outputFile] under.
 *
 * Prefers the server's readable `download_name`, which is also what its
 * `Content-Disposition` carries; the extension comes from the on-disk
 * `filename` when `download_name` has none we accept. When the server sent
 * no usable name, falls back to `crumb-export-<camera id>`. The result never
 * contains a path separator or `..`.
 */
internal fun exportSaveFileName(outputFile: ExportOutputFile): String {
    val friendly = outputFile.downloadName.takeIf { it.isNotBlank() }
    val base = friendly?.let(::sanitizedExportBaseName)
    val extension =
        if (friendly != null && friendly.substringAfterLast('.', "").lowercase() in ALLOWED_EXPORT_EXTENSIONS) {
            sanitizedExportExtension(friendly)
        } else {
            sanitizedExportExtension(outputFile.filename)
        }
    val stem = base ?: ("crumb-export-" + outputFile.cameraId.replace(Regex("[^a-zA-Z0-9_-]"), "_"))
    return "$stem.$extension"
}
