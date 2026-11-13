package com.aiworkdeck.mobile.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import com.aiworkdeck.mobile.design.*
import com.aiworkdeck.mobile.services.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
fun BackupConsentScreen(onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val backend = remember { ServiceLocator.backend.accountSnapshot() }
    var consent by remember { mutableStateOf<BackupConsent?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var disable by remember { mutableStateOf(false) }
    suspend fun load() {
        busy = true; error = null
        try { consent = backend.backupConsent() }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { error = tr("backup.error") }
        finally { busy = false }
    }
    fun save(enabled: Boolean) { scope.launch {
        busy = true; error = null
        try { consent = backend.setBackupConsent(enabled); onClose() }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { error = tr("backup.error") }
        finally { busy = false }
    } }
    LaunchedEffect(Unit) { load() }
    // 与 iOS 同：还没做选择（开启或暂不开启）时不能直接关掉；读取失败时允许关。
    val closable = consent?.decided != false || error != null
    androidx.activity.compose.BackHandler(enabled = !busy) { if (closable) onClose() }
    LightStatusBar()
    WorkdeckTheme(dark = false) {
        Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(Tk.Sp.gutter), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
            Text(tr("backup.title"), style = Fonts.title(), color = Tk.L.fg)
            Text(tr("backup.message"), style = Fonts.body(), color = Tk.L.fg)
            consent?.let { state ->
                Text(tr(if (state.enabled) "backup.enabled" else "backup.disabled"), style = Fonts.small(), color = Tk.L.fgMuted)
                if (!state.canWriteCloud) Text(tr(if (state.cloudAccess?.frozen == true) "postpaid.restricted" else "backup.subscriptionRequired"), style = Fonts.small(), color = if (state.cloudAccess?.frozen == true) Tk.S.failed else Tk.L.fgMuted)
                if (state.enabled) TextButton(onClick = { disable = true }, enabled = !busy) { Text(tr("backup.disable"), color = Tk.S.failed) }
                else if (state.canWriteCloud) com.aiworkdeck.mobile.design.PrimaryButton(tr("backup.enable"), onClick = { save(true) }, enabled = !busy)
                if (!state.decided) TextButton(onClick = { save(false) }, enabled = !busy) { Text(tr("backup.decline"), color = Tk.L.accent) }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tk.L.accent, trackColor = Tk.L.rule)
            error?.let { Text(it, color = Tk.S.failed); TextButton(onClick = { scope.launch { load() } }, enabled = !busy) { Text(tr("project.retry"), color = Tk.L.accent) } }
            if (closable) TextButton(onClick = onClose, enabled = !busy) { Text(tr("common.close"), color = Tk.L.accent) }
        }
        if (disable) AlertDialog(onDismissRequest = { disable = false }, containerColor = Tk.L.bg, titleContentColor = Tk.L.fg, textContentColor = Tk.L.fg, title = { Text(tr("backup.disable"), color = Tk.L.accent) }, text = { Text(tr("backup.disableMessage")) },
            confirmButton = { TextButton(onClick = { disable = false; save(false) }) { Text(tr("backup.disable"), color = Tk.L.accent) } },
            dismissButton = { TextButton(onClick = { disable = false }) { Text(tr("common.cancel"), color = Tk.L.accent) } })
    }
}
