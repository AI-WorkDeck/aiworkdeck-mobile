// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct PersonalMessageView: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: PersonalMessage
    var body: some View {
        Group {
            if message.role == "assistant" {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("personal.aiGenerated")).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("personal.aiGenerated")
                    Text(message.displayedContent).textSelection(.disabled)
                    Button(tr("personal.copyMessage")) { UIPasteboard.general.string = message.copyText }
                        .font(.caption).accessibilityIdentifier("personal.copyMessage")
                }
            } else {
                Text(message.content).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .padding(12).background(message.role == "user" ? T.L.accent.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .tint(colorScheme == .dark ? T.D.fg : T.L.accent)
    }
}
