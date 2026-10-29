package com.aiworkdeck.mobile.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import androidx.core.content.ContextCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * 单次定位。**不接 Google Play services**：国内发行渠道装不上 GMS，取证件的坐标不能建立在
 * 「这台设备恰好有 Google 服务」上——用系统自带的 [LocationManager] 拿一次定位就够了。
 *
 * 拿不到就返回 null：没有坐标的取证件仍然是取证件，编一个坐标才是灾难。
 */
class LocationStamper(private val context: Context) {

    /**
     * 取一次当前位置。超时后退回最后已知位置（室内常见：拿不到新定位，但十分钟前的定位
     * 仍然说明「在这栋楼」），再拿不到返回 null。
     */
    suspend fun current(timeoutMs: Long = 4_000): Loc? {
        if (!granted()) return null
        val lm = context.getSystemService(LocationManager::class.java) ?: return null
        val provider = pickProvider(lm) ?: return null
        // API 29 没有 getCurrentLocation，只能读最后已知位置
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return lastKnown(lm)
        val fresh = withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine { cont ->
                val signal = CancellationSignal()
                cont.invokeOnCancellation { signal.cancel() }
                try {
                    lm.getCurrentLocation(provider, signal, ContextCompat.getMainExecutor(context)) { location ->
                        if (cont.isActive) cont.resume(location?.toLoc())
                    }
                } catch (_: SecurityException) {
                    if (cont.isActive) cont.resume(null)
                }
            }
        }
        return fresh ?: lastKnown(lm)
    }

    private fun pickProvider(lm: LocationManager): String? = when {
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
        lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
        else -> null
    }

    private fun lastKnown(lm: LocationManager): Loc? = try {
        listOfNotNull(
            runCatching { lm.getLastKnownLocation(LocationManager.GPS_PROVIDER) }.getOrNull(),
            runCatching { lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER) }.getOrNull(),
        ).maxByOrNull { it.time }?.toLoc()
    } catch (_: SecurityException) {
        null
    }

    private fun granted(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun Location.toLoc() = Loc(latitude, longitude, if (hasAccuracy()) accuracy.toDouble() else null)
}
