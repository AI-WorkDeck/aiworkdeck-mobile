package com.aiworkdeck.mobile.model

import com.aiworkdeck.contract.ContractStates
import com.aiworkdeck.mobile.design.tr
import java.time.LocalDate
import java.time.ZoneId

data class DaySection(val day: LocalDate, val title: String, val items: List<CaptureItem>)
data class ProjectChoice(val id: String, val name: String)

object LibraryGrouping {
    fun projectId(deviceId: String, key: String) = "$deviceId:$key"

    /** 删除确认等级：按所选里最坏的桶说话。n = 该桶件数；landed 时 n = 总数。 */
    fun deleteWarningLevel(states: List<TransferState>): Pair<String, Int> {
        for (phase in ContractStates.deleteWarnOrder) {
            if (phase == "landed") break
            val n = states.count { it.phase.raw == phase }
            if (n > 0) return ContractStates.deleteWarnLevel.getValue(phase) to n
        }
        return "landed" to states.size
    }

    fun deleteWarning(items: List<CaptureItem>): String {
        val (level, n) = deleteWarningLevel(items.map { it.state })
        return tr(ContractStates.deleteWarnKey.getValue(level), mapOf("n" to n))
    }

    /**
     * 正在看的那个项目里的件。没记项目的件归到 `"unknown"` 桶——它们确实存在，
     * 只是不知道归谁，藏起来比放错地方更糟。
     */
    fun itemsIn(items: List<CaptureItem>, projectId: String?, current: RelayProject? = null): List<CaptureItem> {
        val reference = current?.takeIf { it.id == projectId } ?: items.firstOrNull { it.project?.id == projectId }?.project
        return items.filter { if (reference != null && it.project != null) reference.matches(it.project)
            else (it.project?.id ?: UNKNOWN_PROJECT) == projectId }
    }

    const val UNKNOWN_PROJECT = "unknown"

    /** 按本地自然日分段，新的在前；段内按时间倒序。段头「M月d日 · N 件」。 */
    fun groupByDay(items: List<CaptureItem>, zone: ZoneId = ZoneId.systemDefault()): List<DaySection> =
        items.groupBy { it.capturedAt.atZone(zone).toLocalDate() }.entries
            .sortedByDescending { it.key }
            .map { (day, list) ->
                val sorted = list.sortedByDescending { it.capturedAt }
                DaySection(day, tr("library.dayTitle", mapOf("m" to day.monthValue, "d" to day.dayOfMonth, "n" to sorted.size)), sorted)
            }

    /** 可切换的项目：当前项目永远第一，其余有记录的按名称排；无项目的记录归「未知项目」。 */
    fun projectsIn(items: List<CaptureItem>, current: RelayProject?): List<ProjectChoice> {
        val seen = LinkedHashMap<String, String>()
        for (it in items) {
            val p = it.project
            if (p != null && current?.matches(p) == true) continue
            if (p == null) seen.putIfAbsent(UNKNOWN_PROJECT, tr("library.unknownProject")) else seen.putIfAbsent(p.id, p.name)
        }
        current?.let { seen.remove(it.id) }
        val rest = seen.entries.map { ProjectChoice(it.key, it.value) }.sortedBy { it.name }
        return listOfNotNull(current?.let { ProjectChoice(it.id, it.name) }) + rest
    }
}
