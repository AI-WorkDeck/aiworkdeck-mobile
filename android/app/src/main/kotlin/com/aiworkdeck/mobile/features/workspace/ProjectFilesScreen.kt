package com.aiworkdeck.mobile.features.workspace

import android.content.Intent
import android.content.ClipData
import android.content.Context
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.aiworkdeck.mobile.design.*
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.File

private fun previewIntent(uri: Uri, extension: String) = Intent(Intent.ACTION_VIEW).setDataAndType(uri,
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream")
    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
private fun canPreview(context: Context, extension: String): Boolean =
    previewIntent(Uri.parse("content://${context.packageName}.preview/check.$extension"), extension)
        .resolveActivity(context.packageManager) != null

@Composable
fun ProjectFilesScreen(project: RelayProject, onClose: () -> Unit) {
    val context = LocalContext.current
    val service = remember(project.id) { runCatching { ServiceLocator.backend.projectFiles(File(context.filesDir, "project-previews")) }.getOrNull() }
    if (service == null) {
        WorkdeckTheme(dark = false) {
            Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().padding(Tk.Sp.gutter)) {
                Text(tr("files.error.closed"))
                TextButton(onClick = onClose) { Text(tr("common.close")) }
            }
        }
        return
    }
    val scope = rememberCoroutineScope()
    var files by remember { mutableStateOf(emptyList<ProjectFile>()) }
    var folder by remember { mutableStateOf("") }
    var query by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var truncated by remember { mutableStateOf(false) }
    var quote by remember { mutableStateOf<Pair<ProjectFile, Int>?>(null) }
    suspend fun load() {
        loading = true; error = null
        try { service.files(project).let { files = it.files; truncated = it.truncated } }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message }
        finally { loading = false }
    }
    suspend fun open(file: ProjectFile) {
        busy = true; error = null
        try {
            val local = service.download(project, file)
            val uri = FileProvider.getUriForFile(context, context.packageName + ".preview", local)
            context.startActivity(previewIntent(uri, local.extension).apply { clipData = ClipData.newRawUri("", uri) })
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message ?: tr("files.previewFailed") }
        finally { busy = false }
    }
    fun select(file: ProjectFile) {
        if (busy || loading) return
        scope.launch {
            busy = true; error = null
            try {
                validatePreview(file)
                check(canPreview(context, file.extension)) { tr("files.noPreviewApp") }
                if (isCloudFile(project, file) || service.hasPending(project, file)) open(file)
                else quote = file to service.quote(file)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { error = e.message }
            finally { busy = false }
        }
    }
    LaunchedEffect(service) { load() }
    DisposableEffect(service) { onDispose { service.close() } }
    BackHandler { if (folder.isNotEmpty()) folder = folder.substringBeforeLast('/', "") else onClose() }
    WorkdeckTheme(dark = false) {
        Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().padding(Tk.Sp.gutter)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(project.name, style = Fonts.heading(), modifier = Modifier.weight(1f))
                TextButton(onClick = onClose) { Text(tr("common.close")) }
            }
            OutlinedTextField(value = query, onValueChange = { query = it }, label = { Text(tr("workspace.searchFiles")) }, modifier = Modifier.fillMaxWidth())
            Text(folder.ifEmpty { tr("files.root") }, style = Fonts.small())
            if (folder.isNotEmpty()) TextButton(onClick = { folder = folder.substringBeforeLast('/', "") }) { Text(tr("files.parent")) }
            if (loading || busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(tr(if (loading) "workspace.loading" else "workspace.downloading")) }
            error?.let { Text(it, color = Tk.S.failed); TextButton(onClick = { scope.launch { load() } }, enabled = !busy && !loading) { Text(tr("project.retry")) } }
            if (truncated) Text(tr("workspace.limit"), style = Fonts.small())
            val entries = if (query.isBlank()) folderEntries(files, folder) else files.filter { !it.isFolder && (it.name.contains(query, true) || it.path.contains(query, true)) }.map { FileEntry(it.rowID, it.name, it.path, it) }
            if (entries.isEmpty() && !loading) Text(tr("files.empty"))
            LazyColumn {
                items(entries, key = { it.key }) { entry ->
                    Column(Modifier.fillMaxWidth().clickable(enabled = !busy && !loading) { if (entry.file == null) folder = entry.path else select(entry.file) }.padding(vertical = Tk.Sp.s3)) {
                        Text((if (entry.file == null) "▸ " else "") + entry.name, style = Fonts.body())
                        if (query.isNotEmpty()) Text(entry.path, style = Fonts.small())
                    }
                    Hairline(color = Tk.L.rule)
                }
            }
        }
        quote?.let { (file, credits) ->
            AlertDialog(onDismissRequest = { quote = null }, title = { Text(tr("workspace.download")) },
                text = { Text(tr("workspace.quote", mapOf("name" to file.name, "credits" to credits))) },
                confirmButton = { TextButton(onClick = { quote = null; scope.launch { open(file) } }) { Text(tr("workspace.download")) } },
                dismissButton = { TextButton(onClick = { quote = null }) { Text(tr("common.cancel")) } })
        }
    }
}
