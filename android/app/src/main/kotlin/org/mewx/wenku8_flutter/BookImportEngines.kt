package org.mewx.wenku8_flutter

import android.app.Activity
import android.net.Uri
import java.io.File

/**
 * 上游源码快照未包含的本地导入引擎：目录扫描、EPUB / PDF / MOBI 解析。
 *
 * 这里提供接口齐全的最小占位实现：能编译、调用不崩、Dart 侧拿得到结构正确的空结果，
 * 但不做真实解析。需要真实导入能力时，用完整实现替换本文件即可，调用方无需改动。
 */

internal class BookFolderScanner(@Suppress("UNUSED_PARAMETER") private val activity: Activity) {
    fun canReadAll(): Boolean = false

    fun selectAll() {}

    fun info(): Map<String, Any?> = emptyMap()

    fun setAutomatic(value: Boolean) {}

    fun disconnect() {}

    fun scan(): List<Map<String, Any?>> = emptyList()

    fun formats(): Collection<String> = SUPPORTED_FORMATS

    fun setFormats(extensions: List<String>) {}

    fun stage(token: String, root: File, copy: (Uri, File, Long) -> Unit) {}

    fun link(token: String, links: BookTextLinks, root: File, copy: (Uri, File, Long) -> Unit) {}

    fun markImported(token: String) {}

    fun finish() {}

    fun select(uri: Uri, flags: Int) {}

    private companion object {
        val SUPPORTED_FORMATS = listOf(".epub", ".txt", ".pdf", ".mobi", ".azw3")
    }
}

internal class BookArchiveImport(val root: File) {
    var documents: BookMarkupImport? = null

    fun prepare(name: String, source: BookDocumentInput): Map<String, Any?> =
        throw IllegalStateException("此构建未包含电子书解析引擎")

    companion object {
        const val MAX_ARCHIVE: Long = 512L * 1024 * 1024

        private val EXTENSIONS = listOf(
            ".epub", ".txt", ".pdf", ".mobi", ".azw", ".azw3", ".umd",
            ".html", ".htm", ".md", ".markdown", ".zip",
        )

        fun supported(name: String): Boolean {
            val lower = name.lowercase()
            return EXTENSIONS.any { lower.endsWith(it) }
        }

        fun limit(name: String): Long = MAX_ARCHIVE
    }
}

internal class BookMarkupImport(val root: File, val read: (File) -> ByteArray)

internal class BookPdfImport(
    @Suppress("UNUSED_PARAMETER") private val activity: Activity,
    @Suppress("UNUSED_PARAMETER") private val root: File,
) {
    fun read(file: File): ByteArray = ByteArray(0)
}
