package com.aiworkdeck.mobile.features.personal

import android.content.ClipboardManager
import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.design.tr
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class PersonalMessageDeviceTest {
    @get:Rule val compose = createComposeRule()

    @Test fun assistantCopyIncludesLabelAndUserTextIsNotRelabeled() {
        L10n.locale = "zh-Hans"
        val answer = "Synthetic assistant fixture. No model request was made."
        val user = "User-authored question remains unchanged."
        compose.setContent {
            WorkdeckTheme(dark = false) {
                Column(Modifier.fillMaxSize().background(Tk.L.bg).statusBarsPadding().padding(16.dp)) {
                    Text("SYNTHETIC UI TEST / NOT A MODEL RESPONSE")
                    PersonalMessage("user", user)
                    PersonalMessage("assistant", answer)
                }
            }
        }
        val label = tr("personal.aiGenerated")
        compose.onAllNodesWithText(label).assertCountEquals(1)
        compose.onNodeWithText(user).assertIsDisplayed()
        compose.onNodeWithText(answer).assertIsDisplayed()
        compose.onAllNodesWithText(tr("personal.copyMessage")).assertCountEquals(1)
        compose.onNodeWithText(tr("personal.copyMessage")).performClick()
        compose.runOnIdle {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val clipboard = context.getSystemService(ClipboardManager::class.java)
            assertEquals("$label\n$answer", clipboard.primaryClip!!.getItemAt(0).text.toString())
        }
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        File(instrumentation.targetContext.getExternalFilesDir(null), "synthetic-ai-label.png").outputStream().use {
            instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test fun userMessageAloneHasNoAiLabelOrAssistantCopyAction() {
        compose.setContent { WorkdeckTheme(dark = false) { PersonalMessage("user", "User text") } }
        compose.onNodeWithText(tr("personal.aiGenerated")).assertDoesNotExist()
        compose.onNodeWithText(tr("personal.copyMessage")).assertDoesNotExist()
        compose.onNodeWithText("User text").assertIsDisplayed()
    }
}
