package com.aiworkdeck.mobile.services

import android.content.Context
import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.model.RelayProject
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/** 本机偏好：文件 "prefs"，非敏感设置（相册开关、当前项目、图集的看法），不加密。仅此文件依赖 Android，不参与 JVM 单测。 */
class Prefs(context: Context, private val defaultRegion: AccountRegion) : RegionPrefs {
    private val prefs = context.getSharedPreferences("prefs", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    fun organizeCaptures(scope: String?): Boolean = scope != null && prefs.getBoolean("captureOrganize.enabled.$scope", false)
    fun setOrganizeCaptures(scope: String?, enabled: Boolean) {
        if (scope != null) prefs.edit().putBoolean("captureOrganize.enabled.$scope", enabled).apply()
    }
    fun removeOrganizationResults(ids: Set<String>) {
        val editor = prefs.edit()
        for (key in prefs.all.keys) if (key.startsWith("captureOrganize.result.") && ids.any { key.endsWith(".$it") }) editor.remove(key)
        editor.apply()
    }
    fun clearOrganization(scope: String?) {
        if (scope == null) return
        val editor = prefs.edit().remove("captureOrganize.enabled.$scope")
        for (key in prefs.all.keys) if (key.startsWith("captureOrganize.result.$scope.")) editor.remove(key)
        editor.apply()
    }
    fun organizationResult(scope: String?, id: String): CaptureOrganization? {
        if (scope == null) return null
        return prefs.getString("captureOrganize.result.$scope.$id", null)?.let { try { json.decodeFromString<CaptureOrganization>(it) } catch (_: Exception) { null } }
    }
    fun saveOrganization(scope: String?, id: String, result: CaptureOrganization) {
        if (scope != null) prefs.edit().putString("captureOrganize.result.$scope.$id", json.encodeToString(result)).apply()
    }

    var notificationPermissionAsked: Boolean
        get() = prefs.getBoolean("notificationPermissionAsked", false)
        set(value) { prefs.edit().putBoolean("notificationPermissionAsked", value).apply() }

    var privacyConsentVersion: String?
        get() = prefs.getString("privacyConsentVersion", null)
        set(value) { prefs.edit().putString("privacyConsentVersion", value).apply() }

    val hasPrivacyConsent: Boolean
        get() = privacyConsentVersion == ContractCapabilities.privacyPolicyVersion

    var saveToAlbum: Boolean
        get() = prefs.getBoolean(KEY_SAVE_TO_ALBUM, true)
        set(value) { prefs.edit().putBoolean(KEY_SAVE_TO_ALBUM, value).apply() }

    /**
     * 本机身份。上传时服务端靠它认「哪台手机」，一旦换了值，已经传上去的件与后面传的件
     * 会被当成两台设备——所以只在第一次读取时生成，之后一直沿用，卸载重装才会换。
     */
    val deviceId: String
        get() = prefs.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().lowercase()
            .also { prefs.edit().putString(KEY_DEVICE_ID, it).apply() }

    /**
     * 账号区域（dev-board#837）。没存过就是 flavor 缺省值——包括本功能上线前就登录着的老用户，
     * 他们因此零迁移、仍打原来的主机。只由登录页（未登录态）写入。
     */
    override var accountRegion: AccountRegion
        get() = AccountRegion.resolve(prefs.getString(KEY_ACCOUNT_REGION, null), defaultRegion)
        set(value) { prefs.edit().putString(KEY_ACCOUNT_REGION, value.raw).apply() }

    override var selectedProject: RelayProject?
        get() = prefs.getString(KEY_SELECTED_PROJECT, null)?.let {
            try { json.decodeFromString<RelayProject>(it) } catch (e: Exception) { null }
        }
        set(value) {
            val editor = prefs.edit()
            if (value == null) editor.remove(KEY_SELECTED_PROJECT) else editor.putString(KEY_SELECTED_PROJECT, json.encodeToString(value))
            editor.apply()
        }

    /**
     * 图集怎么看：列数、网格/列表、正在看的项目。
     * 存这儿而不是 `rememberSaveable`：后者只跨配置变更，进程被杀（现场把 app 切后台一会儿
     * 就会）回来又是默认 3 列网格。与 iOS 的 `@AppStorage("libraryColumns"/"libraryViewMode")` 对齐。
     */
    var libraryColumns: Int
        get() = prefs.getInt(KEY_LIBRARY_COLUMNS, 3)
        set(value) { prefs.edit().putInt(KEY_LIBRARY_COLUMNS, value).apply() }

    var libraryViewMode: String
        get() = prefs.getString(KEY_LIBRARY_VIEW_MODE, null) ?: "grid"
        set(value) { prefs.edit().putString(KEY_LIBRARY_VIEW_MODE, value).apply() }

    /** 正在看的项目：可能是已经没记录的项目，图集自己会退回第一项，所以这里只记不校验。 */
    var libraryViewingProject: String?
        get() = prefs.getString(KEY_LIBRARY_VIEWING_PROJECT, null)
        set(value) {
            val editor = prefs.edit()
            if (value == null) editor.remove(KEY_LIBRARY_VIEWING_PROJECT) else editor.putString(KEY_LIBRARY_VIEWING_PROJECT, value)
            editor.apply()
        }

    var appLocale: String
        get() = prefs.getString(KEY_APP_LOCALE, null) ?: "system"
        set(value) {
            val editor = prefs.edit()
            if (value == "system" || value.isBlank()) editor.remove(KEY_APP_LOCALE) else editor.putString(KEY_APP_LOCALE, value)
            editor.apply()
        }

    private companion object {
        const val KEY_SAVE_TO_ALBUM = "saveToAlbum"
        const val KEY_ACCOUNT_REGION = "accountRegion"
        const val KEY_SELECTED_PROJECT = "selectedProject"
        const val KEY_DEVICE_ID = "deviceId"
        const val KEY_LIBRARY_COLUMNS = "libraryColumns"
        const val KEY_LIBRARY_VIEW_MODE = "libraryViewMode"
        const val KEY_LIBRARY_VIEWING_PROJECT = "libraryViewingProject"
        const val KEY_APP_LOCALE = "appLocale"
    }
}
