package com.aiworkdeck.mobile.features.workspace

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.webkit.MimeTypeMap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.PrimaryButton
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.library.PlayerPage
import com.aiworkdeck.mobile.features.library.ZoomablePhoto
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

private fun viewIntent(uri: Uri, extension: String) = Intent(Intent.ACTION_VIEW).setDataAndType(uri,
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream")
    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

/** Checked before any quote: a charged transfer must not start for a format nothing on the phone can open. */
internal fun canOpenExternally(context: Context, extension: String): Boolean =
    viewIntent(Uri.parse("content://${context.packageName}.preview/check.$extension"), extension)
        .resolveActivity(context.packageManager) != null

private fun openExternally(context: Context, file: File): Boolean {
    val uri = FileProvider.getUriForFile(context, context.packageName + ".preview", file)
    val target = viewIntent(uri, file.extension).apply { clipData = ClipData.newRawUri("", uri) }
    return try { context.startActivity(Intent.createChooser(target, tr("files.openWith"))); true }
    catch (_: ActivityNotFoundException) { false }
}

/** In-app preview of a downloaded file; the light pane hosts dark media surfaces like iOS Quick Look. */
@Composable
internal fun FilePreview(file: File, kind: PreviewKind, modifier: Modifier = Modifier) {
    when (kind) {
        PreviewKind.Image -> Box(modifier.background(Color.Black)) { ZoomablePhoto(file) }
        PreviewKind.Pdf -> PdfPages(file, modifier)
        PreviewKind.Audio, PreviewKind.Video -> Box(modifier.background(Color.Black)) { PlayerPage(file, active = true, audio = kind == PreviewKind.Audio) }
        PreviewKind.External -> ExternalPreview(file, modifier)
    }
}

@Composable
private fun ExternalPreview(file: File, modifier: Modifier) {
    val context = LocalContext.current
    var failed by remember(file) { mutableStateOf(false) }
    // Offer the chooser once on arrival; the button stays for reopening.
    LaunchedEffect(file) { failed = !openExternally(context, file) }
    Column(modifier.padding(Tk.Sp.gutter), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
        if (failed) Text(tr("files.noPreviewApp"), style = Fonts.small(), color = Tk.S.failed)
        PrimaryButton(tr("files.openWith"), onClick = { failed = !openExternally(context, file) })
    }
}

/** PdfRenderer allows one open page at a time and is not thread-safe: every access goes through [lock]. */
private class PdfDocument(file: File) {
    private val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    private val renderer = try { PdfRenderer(descriptor) } catch (e: Exception) { descriptor.close(); throw e }
    private val lock = Mutex()
    private var closed = false
    val pageCount: Int = renderer.pageCount

    suspend fun render(index: Int, widthPx: Int): Bitmap? = withContext(Dispatchers.IO) {
        lock.withLock {
            if (closed) return@withLock null
            renderer.openPage(index).use { page ->
                val width = widthPx.coerceIn(1, 2048)
                val height = (width.toLong() * page.height / page.width.coerceAtLeast(1)).toInt().coerceIn(1, 4096)
                Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                    it.eraseColor(android.graphics.Color.WHITE)
                    page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                }
            }
        }
    }

    fun close() {
        CoroutineScope(Dispatchers.IO).launch { lock.withLock { closed = true; renderer.close(); descriptor.close() } }
    }
}

@Composable
private fun PdfPages(file: File, modifier: Modifier) {
    val document = remember(file) { runCatching { PdfDocument(file) }.getOrNull() }
    DisposableEffect(document) { onDispose { document?.close() } }
    if (document == null) {
        Box(modifier.padding(Tk.Sp.gutter)) { Text(tr("files.previewFailed"), style = Fonts.small(), color = Tk.S.failed) }
        return
    }
    BoxWithConstraints(modifier.background(Tk.L.sunken)) {
        val widthPx = constraints.maxWidth
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(Tk.Sp.s2), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
            items(document.pageCount) { index ->
                val bitmap by produceState<Bitmap?>(null, document, index, widthPx) { value = document.render(index, widthPx) }
                val aspect = bitmap?.let { it.width.toFloat() / it.height } ?: 0.707f
                Box(Modifier.fillMaxWidth().aspectRatio(aspect).background(Color.White), contentAlignment = Alignment.Center) {
                    bitmap?.let { Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()) }
                }
            }
        }
    }
}
