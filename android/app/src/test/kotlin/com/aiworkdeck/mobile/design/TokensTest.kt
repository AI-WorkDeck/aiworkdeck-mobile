package com.aiworkdeck.mobile.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.aiworkdeck.contract.T
import com.aiworkdeck.mobile.model.TransferState
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `Tk` 逐字段手写映射自 `T`（无反射）。这里只抽查几个代表字段——真正的把关是编译期：
 * 契约改字段名/加字段，`Tk` 编译不过。以及 [dotColor] 的状态→颜色解析（纯函数，无 Compose 运行时依赖）。
 */
class TokensTest {
    @Test fun colorsMapFromContractArgbLong() {
        assertEquals(Color(T.L.accent), Tk.Paper.Day.accent)
        assertEquals(Color(T.D.surface), Tk.D.surface)
        assertEquals(Color(T.S.failed), Tk.S.failed)
        assertEquals(Color(T.S.movingOnDark), Tk.S.movingOnDark)
    }

    @Test fun spacingMapsIntDpToDp() {
        assertEquals(T.Sp.gutter.dp, Tk.Sp.gutter)
        assertEquals(T.Sp.s4.dp, Tk.Sp.s4)
        assertEquals(T.touchMin.dp, Tk.touchMin)
    }

    @Test fun typeScaleMapsIntSpToSp() {
        assertEquals(T.Ty.body.toFloat(), Tk.Ty.body.value, 0f)
        assertEquals(T.Ty.hero.toFloat(), Tk.Ty.hero.value, 0f)
        assertEquals(T.Ty.nano.toFloat(), Tk.Ty.nano.value, 0f)
    }

    @Test fun dotColorResolvesFailedToSFailedRegardlessOfTheme() {
        assertEquals(Tk.S.failed, dotColor(TransferState.failed, onDark = false))
        assertEquals(Tk.S.failed, dotColor(TransferState.failed, onDark = true))
    }

    @Test fun dotColorResolvesStagedPhaseViaPhaseDotToken() {
        // uploaded 状态属于 staged 桶，phaseDot["staged"] = "S.moving"
        assertEquals(Tk.S.moving, dotColor(TransferState.uploaded, onDark = false))
        assertEquals(Tk.S.movingOnDark, dotColor(TransferState.uploaded, onDark = true))
    }

    @Test fun dotColorResolvesUploadingAndLandedPhases() {
        assertEquals(Tk.S.waiting, dotColor(TransferState.waiting, onDark = false))
        assertEquals(Tk.S.waitingOnDark, dotColor(TransferState.uploading, onDark = true))
        assertEquals(Tk.S.arrived, dotColor(TransferState.arrived, onDark = false))
        assertEquals(Tk.S.arrivedOnDark, dotColor(TransferState.arrived, onDark = true))
    }
}
