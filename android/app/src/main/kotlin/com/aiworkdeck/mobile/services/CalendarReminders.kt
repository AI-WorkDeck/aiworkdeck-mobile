// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.services

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.*
import com.aiworkdeck.mobile.MainActivity
import com.aiworkdeck.mobile.design.tr
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Duration
import java.time.Instant
import java.util.concurrent.TimeUnit

/** Android may defer background work for battery saving. No exact-alarm permission is requested. */
object CalendarReminders {
    private val mutex = Mutex()
    private const val TAG = "personal-calendar"
    private const val CHANNEL = "calendar-reminders"
    private fun prefs(context: Context) = context.getSharedPreferences(TAG, Context.MODE_PRIVATE)
    fun enabled(context: Context): Boolean = prefs(context).getBoolean("enabled", false) && prefs(context).getString("scope", null) == ServiceLocator.backend.personalAccountScope()
    fun enable(context: Context): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        prefs(context).edit().putBoolean("enabled", true).putString("scope", ServiceLocator.backend.personalAccountScope()).apply()
        return true
    }
    suspend fun replace(context: Context, events: List<PersonalCalendarEvent>) = withContext(Dispatchers.IO) { mutex.withLock {
        val manager = WorkManager.getInstance(context)
        manager.cancelAllWorkByTag(TAG).result.get()
        val scope = ServiceLocator.backend.personalAccountScope() ?: return@withLock
        if (!enabled(context)) return@withLock
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(CHANNEL, tr("personal.reminders"), NotificationManager.IMPORTANCE_DEFAULT))
        for (event in reminderEvents(events)) {
            if (ServiceLocator.backend.personalAccountScope() != scope || !enabled(context)) return@withLock
            val request = OneTimeWorkRequestBuilder<CalendarReminderWorker>()
                .setInitialDelay(Duration.between(Instant.now(), event.reminder).toMillis().coerceAtLeast(1), TimeUnit.MILLISECONDS)
                .setInputData(workDataOf("scope" to scope, "eventId" to event.id))
                .addTag(TAG).build()
            manager.enqueueUniqueWork(TAG + ":" + event.id, ExistingWorkPolicy.REPLACE, request).result.get()
        }
        if (ServiceLocator.backend.personalAccountScope() != scope || !enabled(context)) manager.cancelAllWorkByTag(TAG).result.get()
    } }
    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
        WorkManager.getInstance(context).cancelAllWorkByTag(TAG)
        context.getSystemService(NotificationManager::class.java).activeNotifications.filter { it.tag == TAG }.forEach {
            NotificationManagerCompat.from(context).cancel(TAG, it.id)
        }
    }
    fun show(context: Context, data: Data) {
        if (!enabled(context) || ServiceLocator.backend.personalAccountScope() != data.getString("scope")) return
        val id = data.getString("eventId") ?: return
        val intent = Intent(context, MainActivity::class.java).putExtra("calendarEventId", id)
            .setFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(context, id.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.ic_menu_my_calendar)
            .setContentText(tr("personal.reminders")).setContentIntent(pending).setAutoCancel(true).build()
        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            try { NotificationManagerCompat.from(context).notify(TAG, id.hashCode(), notification) } catch (_: SecurityException) { }
        }
    }
}
class CalendarReminderWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        CalendarReminders.show(applicationContext, inputData)
        return Result.success()
    }
}
