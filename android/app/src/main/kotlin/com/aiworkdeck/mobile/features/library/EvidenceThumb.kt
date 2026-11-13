package com.aiworkdeck.mobile.features.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.aiworkdeck.mobile.R
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.MediaKind

/**
 * 缩略图（镜像 iOS `EvidenceThumb`）。录像由全局 ImageLoader 的 `VideoFrameDecoder` 取首帧；
 * 录音没有画面，用声波图标占位——纯装饰，读屏不念（行本身的标签里已有类型）。
 */
@Composable
fun EvidenceThumb(item: CaptureItem, onDark: Boolean, modifier: Modifier = Modifier, iconSize: Dp = 20.dp) {
    Box(modifier.background(if (onDark) Tk.D.surface else Tk.L.sunken), contentAlignment = Alignment.Center) {
        if (item.kind == MediaKind.audio) {
            Icon(
                painterResource(R.drawable.ic_graphic_eq), contentDescription = null,
                tint = if (onDark) Tk.D.fgMuted else Tk.L.fgMuted, modifier = Modifier.size(iconSize),
            )
        } else {
            AsyncImage(
                model = item.localFile,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/** 类型名（照片 / 录像 / 录音），读屏标签与查看器顶栏共用。 */
internal fun kindLabel(kind: MediaKind): String = when (kind) {
    MediaKind.photo -> com.aiworkdeck.mobile.design.tr("home.mode.photo")
    MediaKind.video -> com.aiworkdeck.mobile.design.tr("home.mode.video")
    MediaKind.audio -> com.aiworkdeck.mobile.design.tr("home.mode.audio")
}
