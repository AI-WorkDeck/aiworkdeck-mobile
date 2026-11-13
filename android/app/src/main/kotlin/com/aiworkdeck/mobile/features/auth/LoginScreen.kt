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
import androidx.compose.material3.Checkbox
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import com.aiworkdeck.mobile.design.PrimaryButton
import com.aiworkdeck.mobile.design.Segmented
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.sp
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.BuildConfig
import com.aiworkdeck.mobile.services.mobilePrivacyUrl
import com.aiworkdeck.mobile.services.mobileTermsUrl
import com.aiworkdeck.contract.ContractCapabilities
import androidx.compose.foundation.layout.width
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.aiworkdeck.mobile.design.LightStatusBar
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.services.AccountRegion
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.userFacingMessage
import kotlinx.coroutines.launch

internal enum class Method { Phone, Email }

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

/**
 * 密码登录（与桌面端、官网同一个账号体系）。版式对齐 iOS `LoginView`：
 * 区域分段 + 语言 → 标题与说明 → 登录方式分段 → 账号/密码 → 协议勾选（国内商店要求，未勾选不能登录或注册）
 * → 登录按钮 → 首次使用、忘记密码 → 说明。
 * 审核员与普通用户一样用账号密码登录，不再有单独的「应用商店审核」入口（2026-11-12）。
 */
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
    var agreementsAccepted by remember { mutableStateOf(false) }
    var showLanguagePicker by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    fun clearInputs() { identity = ""; password = ""; error = null }
    fun openFlow(flow: String) {
        if (!agreementsAccepted) { error = tr("login.consentRequired"); return }
        password = ""; error = null
        runCatching { uriHandler.openUri(accountFlowUrl(region, method, flow, BuildConfig.FLAVOR)) }.onFailure { error = tr("login.webError") }
    }
    fun signIn() {
        if (busy) return
        if (!agreementsAccepted) { error = tr("login.consentRequired"); return }
        busy = true; error = null
        scope.launch {
            try { val result = backend.accountLogin(identity.trim(), password); password = ""; model.didLogin(result) }
            catch (e: Exception) { error = userFacingMessage(e) }
            finally { busy = false }
        }
    }
    LightStatusBar()
    Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().imePadding()
        .verticalScroll(rememberScrollState()).padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s4),
        verticalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
            if (ContractCapabilities.intlAccount) {
                Segmented(AccountRegion.entries.map { it to tr(it.labelKey) }, region, enabled = !busy,
                    a11yLabel = tr("login.region.a11y"), modifier = Modifier.weight(1f)) {
                    region = model.switchAccountRegion(); method = defaultMethod(region); clearInputs()
                }
            } else Spacer(Modifier.weight(1f))
            val languageLabel = tr("settings.language")
            Text(
                text = L10n.currentDisplayName + "  ⌄",
                style = Fonts.body(),
                color = Tk.L.accent,
                modifier = Modifier.heightIn(min = Tk.touchMin)
                    .clickable(enabled = !busy) { showLanguagePicker = true }
                    .semantics { contentDescription = languageLabel + " " + L10n.currentDisplayName }
                    .padding(horizontal = Tk.Sp.s2, vertical = Tk.Sp.s2),
            )
        }
        Text(tr("login.title"), style = Fonts.display(), color = Tk.L.fg)
        Text(tr("login.passwordHint"), style = Fonts.micro(), color = Tk.L.fgMuted)
        if (loginMethods(region).size > 1) {
            Segmented(loginMethods(region).map { it to tr(if (it == Method.Phone) "login.phone" else "login.email") }, method,
                enabled = !busy, modifier = Modifier.fillMaxWidth()) { method = it; clearInputs() }
        }
        Column {
            Field(identity, tr(if (method == Method.Phone) "login.phonePlaceholder" else "login.emailPlaceholder"),
                focus, if (method == Method.Phone) KeyboardType.Phone else KeyboardType.Email) {
                if (!busy) identity = it.trim()
            }
            Hairline(color = Tk.L.rule)
            Field(password, tr("login.passwordPlaceholder"), remember { FocusRequester() }, KeyboardType.Password,
                secret = true) { if (!busy) password = it }
            Hairline(color = Tk.L.rule)
        }
        Row(Modifier.fillMaxWidth().toggleable(agreementsAccepted, enabled = !busy, role = Role.Checkbox) { agreementsAccepted = it; if (it) error = null },
            verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = agreementsAccepted, onCheckedChange = null, enabled = !busy)
            Spacer(Modifier.width(Tk.Sp.s2))
            Text(tr("login.consent"), style = Fonts.small(), color = Tk.L.fgMuted)
            Text(tr("login.terms"), style = Fonts.small(), color = Tk.L.accent,
                modifier = Modifier.heightIn(min = Tk.touchMin).clickable(enabled = !busy) { uriHandler.openUri(mobileTermsUrl(BuildConfig.FLAVOR)) }
                    .padding(horizontal = Tk.Sp.s1).wrapContentHeight(Alignment.CenterVertically))
            Text(tr("privacy.policy"), style = Fonts.small(), color = Tk.L.accent,
                modifier = Modifier.heightIn(min = Tk.touchMin).clickable(enabled = !busy) { uriHandler.openUri(mobilePrivacyUrl(BuildConfig.FLAVOR)) }
                    .padding(horizontal = Tk.Sp.s1).wrapContentHeight(Alignment.CenterVertically))
        }
        error?.let { Text(it, style = Fonts.small(), color = Tk.S.failed) }
        Box(contentAlignment = Alignment.Center) {
            PrimaryButton(text = tr(if (busy) "login.working" else "login.title"), onClick = ::signIn,
                enabled = !busy && identity.isNotBlank() && password.isNotEmpty())
            if (busy) CircularProgressIndicator(Modifier.align(Alignment.CenterEnd).padding(end = Tk.Sp.s4).size(18.dp), color = Tk.D.fg, strokeWidth = 2.dp)
        }
        Column {
            LinkRow(tr("login.register"), !busy) { openFlow("register") }
            LinkRow(tr("login.forgotPassword"), !busy) { openFlow("reset") }
        }
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

@Composable
private fun LinkRow(text: String, enabled: Boolean, onClick: () -> Unit) {
    Text(text, style = Fonts.body(), color = if (enabled) Tk.L.accent else Tk.L.fgMuted,
        modifier = Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .wrapContentHeight(Alignment.CenterVertically))
}

@Composable
private fun Field(
    value: String,
    placeholder: String,
    focus: FocusRequester,
    keyboard: KeyboardType,
    secret: Boolean = false,
    onChange: (String) -> Unit,
) {
    val style = Fonts.body().copy(fontSize = 18.sp,
        color = Tk.L.fg,
    )
    BasicTextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        textStyle = style,
        cursorBrush = SolidColor(Tk.L.accent),
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        modifier = Modifier.fillMaxWidth().heightIn(min = Tk.touchMin + Tk.Sp.s2).wrapContentHeight(Alignment.CenterVertically).focusRequester(focus),
        decorationBox = { inner ->
            Box {
                if (value.isEmpty()) Text(placeholder, style = style.copy(color = Tk.L.fgFaint))
                inner()
            }
        },
    )
}

