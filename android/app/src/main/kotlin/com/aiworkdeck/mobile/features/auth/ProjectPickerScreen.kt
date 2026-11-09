package com.aiworkdeck.mobile.features.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.ScreenshotMode
import com.aiworkdeck.mobile.design.LightStatusBar
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.queue.noRipple
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.Unauthorized
import kotlinx.coroutines.launch

/**
 * 选择后续采集或未归类记录的归档目标；关闭仍可继续采集。
 */
@Composable
fun ProjectPickerScreen(model: AppModel, onClose: () -> Unit = {}, markCurrent: Boolean = true, onSelect: (RelayProject) -> Unit = { model.selectProject(it) }) {
    val backend = ServiceLocator.backend
    val current by model.selectedProject.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    var projects by remember { mutableStateOf<List<RelayProject>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        loading = true; error = null
        // 截图机器上没有桌面端，项目列表本来是空态；截图模式给三条演示项目
        if (ScreenshotMode.enabled) {
            projects = ScreenshotMode.projects
            loading = false
            return
        }
        try {
            projects = backend.myProjects()
        } catch (_: Unauthorized) {
            // 会话在别处失效了：回登录页比留在这儿干瞪眼有用
            model.signOut()
            return
        } catch (e: Exception) {
            error = errorText(e)
        }
        loading = false
    }

    LaunchedEffect(Unit) { load() }

    // 选择页只做一件事：尽快点到要的项目。顺序：临时项目 → 最近用过 → 全部；有搜索词时只显示匹配。
    val candidates = projects.filter { !it.isDefault }
    val q = query.trim()
    val matches = if (q.isEmpty()) candidates else candidates.filter { it.name.contains(q, ignoreCase = true) }
    val recent = if (q.isNotEmpty() || candidates.size <= 6) emptyList()
        else ServiceLocator.prefs.recentProjectIds.mapNotNull { id -> candidates.firstOrNull { it.id == id } }
    // 只有项目分布在多台电脑上时，电脑名才帮得上忙。
    val showsDevice = candidates.mapNotNull { it.deviceName?.takeIf { n -> n.isNotEmpty() } }.toSet().size > 1
    val pickNone: () -> Unit = { scope.launch {
        if (loading) return@launch
        loading = true
        try { onSelect(backend.defaultProject()); onClose() }
        catch (e: Exception) { error = errorText(e) }
        finally { loading = false }
    } }
    fun choose(p: RelayProject) { ServiceLocator.prefs.useRecentProject(p.id); onSelect(p) }

    LightStatusBar()
    Column(
        Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().padding(horizontal = Tk.Sp.gutter),
    ) {
        Row(Modifier.padding(top = Tk.Sp.s2), verticalAlignment = Alignment.CenterVertically) {
            Text(tr("project.title"), style = Fonts.heading(), color = Tk.L.fg, maxLines = 1, modifier = Modifier.weight(1f))
            Action(tr("workspace.quickCapture"), onClick = onClose)
        }
        Text(
            text = tr("project.hint", mapOf("date" to ScreenshotMode.archiveDate())),
            style = Fonts.micro(), color = Tk.L.fgFaint, modifier = Modifier.padding(bottom = Tk.Sp.s2),
        )
        OutlinedTextField(
            value = query, onValueChange = { query = it }, singleLine = true,
            placeholder = { Text(tr("workspace.searchProjects")) },
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Tk.L.accent, unfocusedBorderColor = Tk.L.rule, cursorColor = Tk.L.accent),
            modifier = Modifier.fillMaxWidth().padding(bottom = Tk.Sp.s2),
        )

        // 内容区吃掉中间所有空间，页脚（退出登录）永远贴在底下。
        Column(Modifier.weight(1f)) {
            when {
                loading -> Text(
                    tr("project.loading"), style = Fonts.small(), color = Tk.L.fgMuted,
                    modifier = Modifier.heightIn(min = Tk.touchMin).wrapContentHeight(),
                )
                error != null -> Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
                    PickerRow(tr("project.none"), tr("project.noneHint"), markCurrent && current?.isDefault == true, pickNone)
                    Text(error.orEmpty(), style = Fonts.small(), color = Tk.S.failed)
                    Action(tr("project.retry")) { scope.launch { load() } }
                }
                else -> LazyColumn {
                    if (q.isEmpty()) item(key = "none") {
                        PickerRow(tr("project.none"), tr("project.noneHint"), markCurrent && current?.isDefault == true, pickNone)
                    }
                    if (projects.isEmpty()) item(key = "empty") {
                        Column(Modifier.padding(top = Tk.Sp.s4), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                            Text(tr("project.emptyTitle"), style = Fonts.body(), color = Tk.L.fg)
                            Text(tr("empty.projects"), style = Fonts.micro(), color = Tk.L.fgFaint)
                            Action(tr("project.reload")) { scope.launch { load() } }
                        }
                    } else {
                        if (recent.isNotEmpty()) {
                            item(key = "h-recent") { Eyebrow(tr("project.recent"), Modifier.padding(top = Tk.Sp.s4, bottom = Tk.Sp.s1)) }
                            items(recent, key = { "r-" + it.id }) { p ->
                                PickerRow(p.name, p.deviceName.takeIf { showsDevice }, markCurrent && current?.isDefault != true && current?.id == p.id) { choose(p) }
                            }
                            item(key = "h-all") { Eyebrow(tr("personal.allProjects"), Modifier.padding(top = Tk.Sp.s4, bottom = Tk.Sp.s1)) }
                        }
                        items(matches, key = { it.id }) { p ->
                            PickerRow(p.name, p.deviceName.takeIf { showsDevice }, markCurrent && current?.isDefault != true && current?.id == p.id) { choose(p) }
                        }
                        if (matches.isEmpty()) item(key = "no-match") {
                            Text(tr("project.noMatch"), style = Fonts.small(), color = Tk.L.fgMuted,
                                modifier = Modifier.heightIn(min = Tk.touchMin).wrapContentHeight())
                        }
                    }
                }
            }
        }

        Hairline(color = Tk.L.rule)
        Action(
            text = tr("common.signOut"),
            modifier = Modifier.padding(bottom = Tk.Sp.s4),
            color = Tk.L.fgMuted,
        ) { model.signOut() }
    }
}

/** 一行：名称 + 可选小字说明 + 当前项目打勾。 */
@Composable
private fun PickerRow(title: String, subtitle: String?, current: Boolean, onClick: () -> Unit) {
    Column {
        Row(
            Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).clickable(onClick = onClick),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, style = Fonts.body(), color = Tk.L.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                subtitle?.takeIf { it.isNotEmpty() }?.let {
                    Text(it, style = Fonts.nano(), color = Tk.L.fgFaint, maxLines = 1)
                }
            }
            if (current) Text("✓", style = Fonts.body(), color = Tk.L.accent)
        }
        Hairline(color = Tk.L.rule)
    }
}

/** 文字动作。这套视觉里次级动作不做按钮，只做一段可点的强调色文字——且不带默认的方框水波纹。 */
@Composable
private fun Action(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = Tk.L.accent,
    onClick: () -> Unit,
) {
    Text(
        text = text, style = Fonts.small(), color = color,
        modifier = modifier.heightIn(min = Tk.touchMin).noRipple(onClick).wrapContentHeight(),
    )
}
