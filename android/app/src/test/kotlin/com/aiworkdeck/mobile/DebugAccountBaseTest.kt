// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.services.DebugAccountBase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.nio.file.Files

class DebugAccountBaseTest {
    @Test fun acceptsOnlyHttpsLoopbackOrigins() {
        assertEquals("https://localhost:18044", DebugAccountBase.parse("https://localhost:18044/"))
        assertEquals("https://127.0.0.1:18044", DebugAccountBase.parse(" https://127.0.0.1:18044 "))
        assertNull(DebugAccountBase.parse("http://localhost:18044"))
        assertNull(DebugAccountBase.parse("https://addin.aiworkdeck.com"))
        assertNull(DebugAccountBase.parse("https://localhost.evil.example:18044"))
        assertNull(DebugAccountBase.parse("https://localhost:18044/api"))
        assertNull(DebugAccountBase.parse("https://localhost:18044?x=1"))
        assertNull(DebugAccountBase.parse(""))
        assertNull(DebugAccountBase.parse(null))
    }

    @Test fun releaseOrNoCaFileKeepsTheDefaultTrust() {
        val dir = Files.createTempDirectory("dab").toFile()
        File(dir, DebugAccountBase.CA_FILE).writeText("not read in release")
        // Release builds never read the CA file (an unparsable file would throw if they did).
        DebugAccountBase.client(dir, debug = false)
        File(dir, DebugAccountBase.CA_FILE).delete()
        DebugAccountBase.client(dir, debug = true)
    }
}
