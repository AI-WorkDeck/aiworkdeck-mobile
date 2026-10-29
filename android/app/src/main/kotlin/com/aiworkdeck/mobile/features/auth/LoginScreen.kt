package com.aiworkdeck.mobile.features.auth

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.BuildConfig
import com.aiworkdeck.mobile.services.mobilePrivacyUrl
import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.contract.T
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.services.AccountRegion
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.Unauthorized
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.IOException

internal enum class Method { Phone, Email }
private enum class Step { Identity, Code }

/** 这个区域能用哪几种登录方式。国际站没有短信通道，只剩邮箱（dev-board#837）。 */
internal fun loginMethods(region: AccountRegion): List<Method> =
    if (region.allowsPhoneLogin) Method.entries.toList() else listOf(Method.Email)

/** 进登录页（或切了区域）时默认选中的方式：大陆站照旧先手机号，国际站只有邮箱。 */
internal fun defaultMethod(region: AccountRegion): Method = loginMethods(region).first()

/** Fixed origins and a non-identifying marker; no entered credentials leave in browser URLs. */
internal fun accountFlowUrl(region: AccountRegion, method: Method, flow: String, flavor: String): String {
    val host = if (flavor == "intl") {
        if (region == AccountRegion.intl) "https://workdeck.ai/mobile-account/en" else "https://www.aiworkdeck.com/mobile-account/zh"
    } else if (region == AccountRegion.intl) "https://workdeck.ai/en/account" else "https://aiworkdeck.com/zh/account"
    val selectedFlow = if (flow == "reset") "reset" else "register"
    val migration = if (region == AccountRegion.cn && method == Method.Email) "&legacyEmail=1" else ""
    return "$host?flow=$selectedFlow$migration&site=${region.raw}"
}

/** Password login; verification and password creation use the regional website. */
@Composable
fun LoginScreen(model: AppModel) {
    val backend = ServiceLocator.backend
    val scope = rememberCoroutineScope()
    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
    var region by remember { mutableStateOf(ServiceLocator.prefs.accountRegion) }
    var method by remember { mutableStateOf(defaultMethod(region)) }
    var identity by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var reviewMode by remember { mutableStateOf(false) }
    var showLanguagePicker by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    fun openFlow(flow: String) {
        password = ""; error = null; reviewMode = false
        runCatching { uriHandler.openUri(accountFlowUrl(region, method, flow, BuildConfig.FLAVOR)) }.onFailure { error = tr("login.webError") }
    }
    Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().imePadding()
        .verticalScroll(rememberScrollState()).padding(horizontal = Tk.Sp.gutter),
        verticalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            if (ContractCapabilities.intlAccount) {
                RegionToggle(region, !busy) {
                    val next = model.switchAccountRegion()
                    region = next; method = defaultMethod(next); identity = ""; password = ""; error = null; reviewMode = false
                }
            } else {
                Spacer(Modifier.width(1.dp))
            }
            Text(
                text = L10n.currentDisplayName,
                style = Fonts.small(),
                color = Tk.L.fgMuted,
                modifier = Modifier.heightIn(min = Tk.touchMin)
                    .clickable(enabled = !busy) { showLanguagePicker = true }
                    .padding(horizontal = Tk.Sp.s3, vertical = Tk.Sp.s2),
            )
        }
        Text(tr("login.title"), style = Fonts.display(), color = Tk.L.fg)
        Text(tr("login.passwordHint"), style = Fonts.micro(), color = Tk.L.fgMuted)
        if (loginMethods(region).size > 1) {
            MethodPicker(method) { if (!busy) { method = it; identity = ""; password = ""; error = null; reviewMode = false } }
        }
        Field(identity, tr(if (method == Method.Phone) "login.phonePlaceholder" else "login.emailPlaceholder"), 20.sp,
            focus, if (method == Method.Phone) KeyboardType.Phone else KeyboardType.Email) {
            if (!busy) identity = it.trim()
        }
        Hairline(color = Tk.L.rule)
        Field(password, tr(if (reviewMode) "login.reviewCredential" else "login.passwordPlaceholder"), 20.sp, remember { FocusRequester() }, KeyboardType.Password,
            secret = true) { if (!busy) password = it }
        Hairline(color = Tk.L.rule)
        error?.let { Text(it, style = Fonts.micro(), color = Tk.L.fgMuted) }
        Text(tr(if (busy) "login.working" else "login.title"), style = Fonts.heading(), color = Tk.L.accent,
            modifier = Modifier.heightIn(min = Tk.touchMin).clickable(enabled = !busy && identity.isNotBlank() && password.isNotEmpty()) {
                if (busy) return@clickable
                busy = true; error = null
                scope.launch {
                    try {
                        val result = if (!reviewMode) backend.accountLogin(identity.trim(), password)
                            else if (method == Method.Phone) backend.verifyLoginCode(identity.trim(), password)
                            else backend.verifyMailLoginCode(identity.trim(), password)
                        password = ""; model.didLogin(result)
                    }
                    catch (e: Exception) { error = errorText(e) }
                    finally { busy = false }
                }
            })
        Text(tr(if (reviewMode) "login.passwordMode" else "login.review"), style = Fonts.small(), color = Tk.L.fgMuted,
            modifier = Modifier.heightIn(min = Tk.touchMin).clickable(enabled = !busy) { reviewMode = !reviewMode; password = ""; error = null })
        Text(tr("login.register"), style = Fonts.small(), color = Tk.L.accent,
            modifier = Modifier.heightIn(min = Tk.touchMin).clickable(enabled = !busy) { openFlow("register") })
        Text(tr("privacy.policy"), style = Fonts.small(), color = Tk.L.accent,
            modifier = Modifier.heightIn(min = Tk.touchMin).clickable(enabled = !busy) {
                uriHandler.openUri(mobilePrivacyUrl(BuildConfig.FLAVOR))
            })
        Text(tr("login.forgotPassword"), style = Fonts.small(), color = Tk.L.accent,
            modifier = Modifier.heightIn(min = Tk.touchMin).clickable(enabled = !busy) { openFlow("reset") })
        Text(tr(if (region == AccountRegion.cn && method == Method.Email) "login.legacyEmailHint" else "login.webHint"),
            style = Fonts.micro(), color = Tk.L.fgMuted)
    }

    if (showLanguagePicker) {
        AlertDialog(
            onDismissRequest = { showLanguagePicker = false },
            title = { Text(tr("settings.language")) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    val options = listOf(L10n.SYSTEM_PREFERENCE to tr("settings.languageFollowSystem")) +
                        L10n.supportedLocales.map { it.code to it.nativeName }
                    for ((code, label) in options) {
                        val selected = L10n.preference == code
                        Text(
                            text = label,
                            style = Fonts.body(),
                            color = if (selected) Tk.L.accent else Tk.L.fg,
                            modifier = Modifier.fillMaxWidth().heightIn(min = Tk.touchMin)
                                .clickable {
                                    ServiceLocator.prefs.appLocale = code
                                    L10n.applyPreference(code, region)
                                    showLanguagePicker = false
                                }
                                .padding(vertical = Tk.Sp.s2),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showLanguagePicker = false }) { Text(tr("common.close")) }
            },
        )
    }
}

/** 全大写、字距拉开的小标签——这套排版的签名。 */
@Composable
internal fun Eyebrow(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = Fonts.nano(), color = Tk.L.fgMuted, modifier = modifier)
}

/**
 * 区域开关：一条圆角轨道里并排两个短标签，滑块垫在当前那一个下面，点胶囊任意处翻到另一边，
 * 滑块按动画令牌滑过去。整个胶囊是一个可点目标（外层撑到 touchMin 高），读屏念 login.region.a11y + 当前标签。
 * 颜色全用现有令牌：轨道 sunken + rule 描边，滑块 accent，选中字反白（bg）。
 */
@Composable
private fun RegionToggle(current: AccountRegion, enabled: Boolean, onToggle: () -> Unit) {
    val density = LocalDensity.current
    // 两个标签各自量出来的位置与宽度：中英文标签长短不一，不能假设两格等宽
    val slots = remember { mutableStateMapOf<AccountRegion, Pair<Dp, Dp>>() }
    val shape = RoundedCornerShape(percent = 50)
    val a11y = tr("login.region.a11y")
    val valueLabel = tr(current.labelKey)
    Box(
        Modifier.heightIn(min = Tk.touchMin)
            .clickable(enabled = enabled, role = Role.Switch) { onToggle() }
            // 读屏只念一句「切换…」+ 当前标签，不把轨道里两个标签再各念一遍
            .clearAndSetSemantics {
                contentDescription = a11y
                stateDescription = valueLabel
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.clip(shape).background(Tk.L.sunken).border(1.dp, Tk.L.rule, shape).padding(Tk.Sp.s1 / 2)) {
            slots[current]?.let { (x, w) ->
                val spec = tween<Dp>(T.Motion.baseMs)
                val thumbX by animateDpAsState(x, spec, label = "regionThumbX")
                val thumbW by animateDpAsState(w, spec, label = "regionThumbW")
                Box(Modifier.matchParentSize()) {
                    Box(Modifier.offset(x = thumbX).width(thumbW).fillMaxHeight().clip(shape).background(Tk.L.accent))
                }
            }
            Row {
                for (r in AccountRegion.entries) {
                    Text(
                        text = tr(r.labelKey),
                        style = Fonts.small(), color = if (r == current) Tk.L.bg else Tk.L.fgMuted,
                        modifier = Modifier
                            .onGloballyPositioned { c ->
                                slots[r] = with(density) { c.positionInParent().x.toDp() to c.size.width.toDp() }
                            }
                            .padding(horizontal = Tk.Sp.s3, vertical = Tk.Sp.s1),
                    )
                }
            }
        }
    }
}

/**
 * 两个方式之间切换。切换要清掉验证码与报错，否则会出现「填了邮箱、报的是手机号那条的错」
 * 这种对不上号的状态。
 */
@Composable
private fun MethodPicker(current: Method, modifier: Modifier = Modifier, onPick: (Method) -> Unit) {
    Row(
        modifier.heightIn(min = Tk.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s5),
    ) {
        for (m in Method.entries) {
            Text(
                text = tr(if (m == Method.Phone) "login.phone" else "login.email"),
                style = Fonts.small(), color = if (m == current) Tk.L.accent else Tk.L.fgMuted,
                modifier = Modifier.clickable { onPick(m) },
            )
        }
    }
}

@Composable
private fun Field(
    value: String,
    placeholder: String,
    mono: TextUnit,
    focus: FocusRequester,
    keyboard: KeyboardType,
    letterSpacing: Boolean = false,
    secret: Boolean = false,
    onChange: (String) -> Unit,
) {
    val style = Fonts.mono(mono, FontWeight.Light).copy(
        color = Tk.L.fg, letterSpacing = if (letterSpacing) 0.3.em else TextStyle.Default.letterSpacing,
    )
    BasicTextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        textStyle = style,
        cursorBrush = SolidColor(Tk.L.accent),
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        modifier = Modifier.fillMaxWidth().focusRequester(focus),
        decorationBox = { inner ->
            Box {
                if (value.isEmpty()) Text(placeholder, style = style.copy(color = Tk.L.fgFaint))
                inner()
            }
        },
    )
}

/** 只做「明显不是邮箱」的拦截，不做 RFC 校验——真正的判定在后端，客户端把合法地址挡下来更糟。 */
internal fun looksLikeEmail(email: String): Boolean {
    val at = email.indexOf('@')
    if (at <= 0) return false
    val domain = email.substring(at + 1)
    return domain.contains('.') && !domain.startsWith('.') && !domain.endsWith('.')
}

/** 回显发到哪去了，但不把标识完整重复一遍——旁边有人时那是一次不必要的泄露。 */
private fun mask(method: Method, value: String): String = when (method) {
    Method.Phone -> if (value.length < 7) value else value.take(3) + "****" + value.takeLast(4)
    Method.Email -> {
        val at = value.indexOf('@')
        if (at < 0) value else {
            val name = value.substring(0, at)
            (if (name.length <= 1) "***" else name.take(1) + "***") + value.substring(at)
        }
    }
}

/**
 * 报错文案。网络失败与业务失败要分开说——用户看到「验证码错误」和看到「网络不通」，
 * 下一步该做什么完全不同。
 */
internal fun errorText(e: Throwable): String = when (e) {
    is Unauthorized -> tr("error.unauthorized")
    is IOException -> tr("error.network")
    is ApiError -> e.message ?: tr("error.network")
    else -> e.message ?: tr("error.network")
}
