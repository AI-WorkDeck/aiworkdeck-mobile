// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services.firm

import com.aiworkdeck.contract.ContractCapabilities
import java.net.URI
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime

// Pure firm-review logic, ported 1:1 from iOS (FirmPortal.swift, FirmInboxView/FirmMatterView/FirmSheets helpers)
// and tested in FirmReviewTest.kt mirroring ios/Tests/FirmReviewTests.swift.

object FirmInbox {
    enum class Group { needsYou, waiting, inProgress, done }

    /** Why a matter needs the lawyer now, or null. A portal's explicit `attention` (even "") wins over the guess. */
    fun reason(m: FirmMatterSummary): String? {
        m.attention?.let { return it.takeIf { a -> a in setOf("review_requested", "call_requested", "client_replied") } }
        if (m.consult?.status == "requested") return "call_requested"
        if (m.status == "review") return "review_requested"
        return null
    }

    fun group(m: FirmMatterSummary): Group = when {
        m.status in setOf("signed", "closed") -> Group.done
        reason(m) != null -> Group.needsYou
        m.status == "awaiting_client" -> Group.waiting
        else -> Group.inProgress
    }

    fun grouped(list: List<FirmMatterSummary>): List<Pair<Group, List<FirmMatterSummary>>> =
        Group.entries.mapNotNull { g -> list.filter { group(it) == g }.takeIf { it.isNotEmpty() }?.let { g to it } }

    fun reasonKey(reason: String): String = when (reason) {
        "call_requested" -> "firm.reason.call"
        "client_replied" -> "firm.reason.reply"
        else -> "firm.reason.review"
    }

    fun titleKey(g: Group): String = when (g) {
        Group.needsYou -> "firm.inbox.needsYou"
        Group.waiting -> "firm.inbox.waiting"
        Group.inProgress -> "firm.inbox.inProgress"
        Group.done -> "firm.inbox.done"
    }

    /** What stands in for an empty list: a spinner until the first load, "nothing here" after it, nothing on error. */
    enum class Placeholder { loading, empty }
    fun placeholder(hasMatters: Boolean, listed: Boolean, failed: Boolean): Placeholder? =
        if (hasMatters || failed) null else if (listed) Placeholder.empty else Placeholder.loading
}

object FirmDiff {
    sealed class Change { data class Same(val text: String) : Change(); data class Added(val text: String) : Change(); data class Removed(val text: String) : Change() }

    fun paragraphs(markdown: String): List<String> =
        markdown.replace("\r\n", "\n").split("\n\n").map { it.trim() }.filter { it.isNotEmpty() }

    /** Non-empty lines as the reader sees them: heading marks, bold and spacing are not changes of text. */
    fun lines(markdown: String): List<String> = markdown.replace("\r\n", "\n").split("\n").map(::visible).filter { it.isNotEmpty() }

    fun visible(line: String): String {
        var s = line.trim(' ', '\t')
        while (s.startsWith("#")) s = s.substring(1)
        s = s.replace("**", "")  // "__" stays: underscore blanks are content in drafts
        return s.split(' ', '\t').filter { it.isNotEmpty() }.joinToString(" ")
    }

    /** LCS over lines; the full edit script in document order. */
    fun changes(old: String, new: String): List<Change> {
        val a = lines(old); val b = lines(new)
        val n = a.size; val m = b.size
        val lcs = Array(n + 1) { IntArray(m + 1) }
        for (i in n - 1 downTo 0) for (j in m - 1 downTo 0) {
            lcs[i][j] = if (a[i] == b[j]) lcs[i + 1][j + 1] + 1 else maxOf(lcs[i + 1][j], lcs[i][j + 1])
        }
        val out = mutableListOf<Change>()
        var i = 0; var j = 0
        while (i < n && j < m) {
            when {
                a[i] == b[j] -> { out += Change.Same(a[i]); i++; j++ }
                lcs[i + 1][j] >= lcs[i][j + 1] -> { out += Change.Removed(a[i]); i++ }
                else -> { out += Change.Added(b[j]); j++ }
            }
        }
        while (i < n) out += Change.Removed(a[i++])
        while (j < m) out += Change.Added(b[j++])
        return out
    }

    /** Only what changed. */
    fun edits(old: String, new: String): List<Change> = changes(old, new).filter { it !is Change.Same }
}

object FirmPortalLink {
    /**
     * A firm link (`https://host/office/...`) or bare `host/office` → the allowlisted portal id. Only https; the office
     * is the whole first path segment. The site root resolves to `host/all` when listed; anything else unlisted is refused.
     */
    fun portal(input: String, allowed: List<String> = ContractCapabilities.firmPortals): String? {
        val text = input.trim()
        if (text.isEmpty()) return null
        val uri = runCatching { URI(if ("://" in text) text else "https://$text") }.getOrNull() ?: return null
        if (uri.scheme?.lowercase() != "https" || uri.rawUserInfo != null) return null
        val host = uri.host?.lowercase() ?: return null
        val first = (uri.path ?: "").split("/").firstOrNull { it.isNotEmpty() }?.lowercase()
        if (first != null) return (host + "/" + first).takeIf { it in allowed }
        if ("$host/all" in allowed) return "$host/all"
        return host.takeIf { it in allowed }
    }

    /** Host and path prefix ("" or "/office") of a portal id. */
    fun parts(portal: String): Pair<String, String> {
        val p = portal.split("/", limit = 2)
        return p[0] to (if (p.size > 1) "/" + p[1] else "")
    }

    /** Debug builds only: a local portal server for journeys without production accounts (see FirmSeed). */
    @Volatile var debugBase: URI? = null

    /**
     * Seed mode only: a portal URL (the server writes absolute https://<portal host>/... links) is fetched from the
     * local seed portal instead, so nothing reaches production. Outside seed mode the URL is returned unchanged.
     */
    fun localize(url: String, allowed: List<String> = ContractCapabilities.firmPortals): String {
        val b = debugBase ?: return url
        val uri = runCatching { URI(url) }.getOrNull() ?: return url
        if (uri.scheme != "https" || uri.host !in allowed.map { parts(it).first }) return url
        return URI(b.scheme, null, b.host, b.port, uri.rawPath, uri.rawQuery, null).toString()
    }

    /** PDFs and other portal links open only when they point at an allowlisted https host. */
    fun isPortalUrl(url: String, allowed: List<String> = ContractCapabilities.firmPortals): Boolean {
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        debugBase?.let { b -> if (uri.host == b.host && uri.port == b.port && uri.rawUserInfo == null) return true }
        return uri.scheme == "https" && uri.rawUserInfo == null && allowed.map { parts(it).first }.contains(uri.host)
    }
}

/** What a linked portal lets the account do. Only an explicit approval shows the Reviews tab. */
enum class FirmAccess {
    none, checking, pending, approved, revoked, failed;

    companion object {
        /** Error codes meaning the credential no longer opens this portal. */
        val lostAccessCodes = setOf("access_revoked", "unauthorized", "trial_expired")

        fun forStatus(status: String?): FirmAccess = when (status) {
            "approved" -> approved
            "revoked" -> revoked
            else -> pending
        }

        /** After a failed check: the portal's verdict if it gave one; otherwise the last state stands (never upgraded). */
        fun after(errorCode: String, previous: FirmAccess): FirmAccess = when {
            errorCode in lostAccessCodes -> revoked
            errorCode == "access_pending" -> pending
            previous in setOf(none, checking, failed) -> failed
            else -> previous
        }

        /** Several portals: approved wins, then checking, pending, revoked, failed. */
        fun combined(all: List<FirmAccess>): FirmAccess =
            listOf(approved, checking, pending, revoked, failed).firstOrNull { it in all } ?: none
    }
}

/** A portal error: `error` from the reply, `http_N`, `network` or `bad_response`. */
class FirmPortalError(val code: String, val status: Int) : Exception(code) {
    /** Contract string key for what the lawyer sees. */
    val messageKey: String
        get() = when (code) {
            "version_changed" -> "firm.error.versionChanged"
            "already_signed" -> "firm.error.alreadySigned"
            "access_pending", "access_revoked", "unauthorized", "trial_expired" -> "firm.error.access"
            else -> "firm.error.network"
        }
}

/** Who signs a matter: the signed-in identity, never typed. A trial code or unlinked demo signs as the matter's lawyer. */
data class FirmSigner(val name: String, val detail: String? = null, val demo: Boolean)

object FirmIdentity {
    fun signer(kind: String?, demo: Boolean, rosterName: String?, title: String?, office: String?,
               accountName: String?, matterLawyer: String?, firmName: String): FirmSigner? {
        fun nonEmpty(s: String?) = s?.takeIf { it.isNotEmpty() }
        if (kind == "lawyer") nonEmpty(rosterName)?.let { n ->
            val detail = listOfNotNull(nonEmpty(title), nonEmpty(office)).joinToString(" · ")
            return FirmSigner(n, detail.ifEmpty { null }, demo = false)
        }
        if (kind == "lawyer" && !demo) return nonEmpty(accountName)?.let { FirmSigner(it, demo = false) }
        return nonEmpty(nonEmpty(matterLawyer) ?: firmName)?.let { FirmSigner(it, demo = true) }
    }

    /** Account scope (region host + user id): one account's links and codes are never used by another. Same as iOS. */
    fun accountScope(userId: Long, base: String): String =
        MessageDigest.getInstance("SHA-256").digest("$base#$userId".toByteArray()).joinToString("") { "%02x".format(it) }

    fun trialAccount(scope: String, portal: String) = "$scope|$portal"
    fun detailsKey(scope: String, portal: String) = "firm.own." + trialAccount(scope, portal) + "."

    /** Sign-off needs every confirmation and a signer. */
    fun signoffReady(conflicts: Boolean, engagement: Boolean, reviewed: Boolean, signer: FirmSigner?) =
        conflicts && engagement && reviewed && signer != null

    fun settlementKey(s: String?): String = when (s) {
        "noted" -> "firm.flag.noted"
        "kept" -> "firm.flag.kept"
        "lawyer" -> "firm.flag.lawyer"
        else -> "firm.flag.open"
    }
}

object FirmText {
    /** "2" → "§2"; named sections stay as they are. */
    fun section(s: String?): String? = s?.takeIf { it.isNotEmpty() }?.let { if (it.first().isDigit()) "§$it" else it }

    /** Who the matter is for, else the document's name, else a dash (synthetic or unnamed matters). */
    fun title(client: String?, company: String?, document: String?): String =
        who(client, company).takeIf { it != "—" } ?: document?.takeIf { it.isNotBlank() } ?: "—"

    /** The call line: with the proposed times when the client gave some, without a dangling separator otherwise. */
    fun callLine(times: String?): Pair<String, Map<String, Any>> =
        if (times.isNullOrBlank()) "firm.reason.call" to emptyMap() else "firm.matter.call" to mapOf("times" to times)

    fun who(client: String?, company: String?): String =
        listOfNotNull(company, client).filter { it.isNotEmpty() }.joinToString(" · ").ifEmpty { "—" }

    fun instant(iso: String): Instant? = runCatching { OffsetDateTime.parse(iso).toInstant() }.getOrNull()

    /** A server clock slightly ahead must never read as the future. */
    fun clampToNow(iso: String, now: Instant = Instant.now()): Instant? = instant(iso)?.let { if (it.isAfter(now)) now else it }
}

object FirmMarkdown {
    data class Block(val level: Int, val text: String)

    /** Text without emphasis or heading marks, for plain display. */
    fun plain(block: String): String = block.replace("**", "").replace("#", "").trim(' ', '\t')

    /** Every `#` line is its own heading; body lines between headings stay together. */
    fun blocks(markdown: String): List<Block> {
        val out = mutableListOf<Block>()
        for (paragraph in FirmDiff.paragraphs(markdown)) {
            val body = mutableListOf<String>()
            fun flush() { if (body.isNotEmpty()) { out += Block(0, body.joinToString("\n")); body.clear() } }
            for (line in paragraph.split("\n")) {
                val t = line.trim(' ', '\t')
                if (t.startsWith("#")) {
                    flush()
                    out += Block(t.takeWhile { it == '#' }.length, t.dropWhile { it == '#' }.trim(' ', '\t'))
                } else if (t.isNotEmpty()) body += line
            }
            flush()
        }
        return out
    }
}

/** What a linked portal's row and the Settings entry say (iOS FirmJoinView.status / SettingsView.firmStatus). */
object FirmStatus {
    /** Contract key and variables for one linked portal, or null when only the firm name is shown. */
    fun link(access: FirmAccess, firmName: String): Pair<String, Map<String, Any>>? = when (access) {
        FirmAccess.pending, FirmAccess.checking -> "firm.status.pending" to mapOf("firm" to firmName)
        FirmAccess.revoked -> "firm.status.revoked" to mapOf("firm" to firmName)
        FirmAccess.failed, FirmAccess.none -> null
        FirmAccess.approved -> "firm.status.approved" to mapOf("firm" to firmName)
    }

    /**
     * Settings value from each linked portal's (access, firm name): the approved firms' names, else the first
     * linked firm as pending, else nothing. Returns plain text or a contract key with variables.
     */
    fun settings(links: List<Pair<FirmAccess, String>>): SettingsValue? = when (FirmAccess.combined(links.map { it.first })) {
        FirmAccess.approved -> SettingsValue.Text(links.filter { it.first == FirmAccess.approved }.joinToString(", ") { it.second })
        FirmAccess.pending, FirmAccess.checking -> links.firstOrNull()?.let { SettingsValue.Key("firm.status.pending", mapOf("firm" to it.second)) }
        else -> null
    }
    sealed class SettingsValue { data class Text(val text: String) : SettingsValue(); data class Key(val key: String, val vars: Map<String, Any>) : SettingsValue() }
}

/** Tabs and their visibility (iOS PersonalWorkspaceView: the Reviews tab exists only while a firm approves the account). */
object FirmTabs {
    /** The tab to stay on when the Reviews tab disappears while selected (POLISH M10 on iOS). */
    fun <T> keep(selected: T, firmTab: T, fallback: T, firmVisible: Boolean): T = if (!firmVisible && selected == firmTab) fallback else selected

    /** "3 min ago"-style label as a contract key and number; never in the future. */
    fun agoKey(then: Instant, now: Instant = Instant.now()): Pair<String, Long> {
        val s = maxOf(0, java.time.Duration.between(then, now).seconds)
        return when {
            s < 60 -> "time.secondsAgo" to s
            s < 3600 -> "time.minutesAgo" to s / 60
            s < 86400 -> "time.hoursAgo" to s / 3600
            else -> "time.daysAgo" to s / 86400
        }
    }
}

object FirmPdf {
    /** Signed PDFs on this device; the app deletes this folder on sign-out and account deletion. */
    fun folder(filesDir: java.io.File) = java.io.File(filesDir, "project-previews/firm")

    /** PDF downloads never follow redirects: only the allowlisted URL may serve the signed document. */
    val client: okhttp3.OkHttpClient by lazy {
        OkHttpFirmTransport.defaultClient.newBuilder().followRedirects(false).followSslRedirects(false).build()
    }

    /** A portal reply is shown as a PDF only if it is one (an error page must not be saved as the signed document). */
    fun looksLikePdf(bytes: ByteArray): Boolean = bytes.size >= 5 && String(bytes, 0, 5, Charsets.US_ASCII) == "%PDF-"
}
