import ActivityKit
import SwiftUI
import WidgetKit

/// 录音 Live Activity：锁屏 / 横幅卡片 + 灵动岛。
/// 计时用 Text(timerInterval:) 自走、不靠推送；中断时显示 elapsedBase 的静态值。
/// 文案走词典键（L10n + ContractStrings 与 App 共用同一份源码），配色用深色令牌。
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingCard(projectName: context.attributes.projectName, locale: context.attributes.locale,
                          state: context.state)
                .padding(T.Sp.s4)
                .activityBackgroundTint(T.D.bg)
                .activitySystemActionForegroundColor(T.D.fg)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: T.Sp.s2) {
                        RecordingDot(paused: context.state.paused)
                        Text(tr(context.state.paused ? "rec.pause.status" : "home.recording.audio", locale: context.attributes.locale))
                            .font(T.F.nano())
                            .tracking(0.4)
                            .foregroundStyle(T.D.fgMuted)
                    }
                    .padding(.leading, T.Sp.s2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTimer(state: context.state)
                        .font(T.F.mono(17, .medium))
                        .foregroundStyle(T.D.fg)
                        .padding(.trailing, T.Sp.s2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: T.Sp.s2) {
                        Text(context.attributes.projectName)
                            .font(T.F.heading())
                            .foregroundStyle(T.D.fg)
                            .lineLimit(1)
                        if context.state.paused {
                            PausedNotice(locale: context.attributes.locale)
                        }
                        StopButton(locale: context.attributes.locale)
                    }
                    .padding(.horizontal, T.Sp.s2)
                }
            } compactLeading: {
                RecordingDot(paused: context.state.paused)
            } compactTrailing: {
                RecordingTimer(state: context.state)
                    .font(T.F.mono(13, .medium))
                    .foregroundStyle(T.D.fg)
                    // 定宽：数字每秒变化，不定宽会让灵动岛跟着抖
                    .frame(width: 44, alignment: .trailing)
            } minimal: {
                RecordingDot(paused: context.state.paused)
            }
        }
    }
}

// MARK: - 锁屏 / 横幅

private struct RecordingCard: View {
    let projectName: String
    let locale: String?
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: T.Sp.s3) {
            HStack(spacing: T.Sp.s2) {
                RecordingDot(paused: state.paused)
                Text(tr(state.paused ? "rec.pause.status" : "home.recording.audio", locale: locale))
                    .font(T.F.nano())
                    .tracking(0.4)
                    .foregroundStyle(T.D.fgMuted)
                Spacer()
                RecordingTimer(state: state)
                    .font(T.F.mono(21, .medium))
                    .foregroundStyle(T.D.fg)
            }
            Text(projectName)
                .font(T.F.heading())
                .foregroundStyle(T.D.fg)
                .lineLimit(1)
            if state.paused {
                PausedNotice(locale: locale)
            }
            StopButton(locale: locale)
        }
    }
}

// MARK: - 零件

private struct RecordingDot: View {
    var paused: Bool
    var body: some View {
        if paused {
            Image(systemName: "pause.fill").foregroundStyle(T.S.waitingOnDark)
        } else {
            Circle().fill(T.S.failed).frame(width: 8, height: 8)
        }
    }
}

private struct PausedNotice: View {
    let locale: String?

    var body: some View {
        Text(tr("rec.pause.remember", locale: locale))
            .font(T.F.micro())
            .foregroundStyle(T.S.waitingOnDark)
    }
}

/// 停止意图在主进程执行（见 StopRecordingIntent）。
private struct StopButton: View {
    let locale: String?

    var body: some View {
        Button(intent: StopRecordingIntent()) {
            Text(tr("home.shutter.stopAudio", locale: locale))
                .font(T.F.small())
                .frame(maxWidth: .infinity, minHeight: T.touchMin)
        }
        .buttonStyle(.borderedProminent)
        .tint(T.S.failed)
    }
}

/// 运行中：以 resumedAt - elapsedBase 为起点自走；中断中：静态 mm:ss。
private struct RecordingTimer: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if let resumedAt = state.resumedAt, !state.paused {
            Text(timerInterval: resumedAt.addingTimeInterval(-state.elapsedBase)...Date.distantFuture,
                 countsDown: false)
                .monospacedDigit()
        } else {
            Text(Self.mmss(state.elapsedBase))
                .monospacedDigit()
        }
    }

    private static func mmss(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
