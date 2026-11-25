// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// First-launch privacy notice (same text as Android). iOS has no "decline and exit": apps must not quit
/// themselves, so the user can read the documents or leave the app the usual way.
struct PrivacyConsentView: View {
    let onAccept: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.Sp.s6) {
                Text(tr("privacy.title")).font(T.F.display()).foregroundStyle(T.L.fg)
                    .accessibilityIdentifier("privacy.title")
                Text(tr("privacy.summary")).font(T.F.body()).foregroundStyle(T.L.fg)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: T.Sp.s2) {
                    Button(tr("login.terms")) { openURL(AccountRegion.current.termsURL) }
                        .frame(minHeight: T.touchMin).accessibilityIdentifier("privacy.terms")
                    Button(tr("privacy.policy")) { openURL(AccountRegion.current.privacyURL) }
                        .frame(minHeight: T.touchMin).accessibilityIdentifier("privacy.policy")
                }
                .font(T.F.body()).foregroundStyle(T.L.accent)
                Button(action: onAccept) {
                    Text(tr("privacy.accept")).font(T.F.body()).frame(maxWidth: .infinity, minHeight: T.touchMin)
                }
                .buttonStyle(.borderedProminent).tint(T.L.accent)
                .accessibilityIdentifier("privacy.accept")
            }
            .padding(T.Sp.gutter)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(T.L.bg)
        .preferredColorScheme(.light)
    }
}
