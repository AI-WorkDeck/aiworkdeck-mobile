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
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.ScreenshotMode
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
 * 选归档目标。登录后必走一次——不选项目就不知道照片该往哪去，与其让人先拍完再问，
 * 不如进门就定。镜像 iOS `ProjectPickerView`。
 */
@Composable
fun ProjectPickerScreen(model: AppModel) {
    val backend = ServiceLocator.backend
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

    Column(
        Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().padding(horizontal = Tk.Sp.gutter),
    ) {
        Column(
            Modifier.padding(top = Tk.Sp.s10, bottom = Tk.Sp.s6),
            verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
        ) {
            Eyebrow(tr("project.eyebrow"))
            Text(tr("project.title"), style = Fonts.display(), color = Tk.L.fg)
            Text(
                text = tr("project.hint", mapOf("date" to ScreenshotMode.archiveDate())),
                style = Fonts.micro(), color = Tk.L.fgFaint,
            )
        }

        // 内容区吃掉中间所有空间，页脚（退出登录）永远贴在底下。
        Column(Modifier.weight(1f)) {
            when {
                loading -> Text(
                    tr("project.loading"), style = Fonts.small(), color = Tk.L.fgMuted,
                    modifier = Modifier.heightIn(min = Tk.touchMin).wrapContentHeight(),
                )
                error != null -> Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
                    Text(error.orEmpty(), style = Fonts.small(), color = Tk.S.failed)
                    Action(tr("project.retry")) { scope.launch { load() } }
                }
                projects.isEmpty() -> Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                    Text(tr("project.emptyTitle"), style = Fonts.body(), color = Tk.L.fg)
                    Text(tr("empty.projects"), style = Fonts.micro(), color = Tk.L.fgFaint)
                    Action(tr("project.reload")) { scope.launch { load() } }
                }
                else -> LazyColumn {
                    items(projects, key = { it.id }) { p ->
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = Tk.touchMin)
                                .clickable { model.selectProject(p) },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(p.name, style = Fonts.body(), color = Tk.L.fg, maxLines = 1)
                                p.projectUid?.let {
                                    Text(tr("project.unifiedIdentity", mapOf("id" to it)), style = Fonts.nano(), color = Tk.L.fgFaint)
                                }
                                p.deviceName?.takeIf { it.isNotEmpty() }?.let {
                                    Text(it, style = Fonts.nano(), color = Tk.L.fgFaint)
                                }
                            }
                            Text("›", style = Fonts.body(), color = Tk.L.fgFaint)
                        }
                        Hairline(color = Tk.L.rule)
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
