import SwiftUI
import VoiceChatKit

// Spec §17 — the strip a debate seat shows above its panes: which side this
// window argues, how far the debate has run, and what it is waiting for.
//
// Every value is derived from the badge the coordinator pushes in. The bar
// sets nothing itself except the two moderator actions.

struct DebateBar: View {
    let badge: DebateBadge
    @Binding var autoHandoff: Bool
    let onSkip: () -> Void
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2.fill")
                .foregroundStyle(Glass.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(badge.seatName.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(scheme.accentText)
                Text(badge.motion)
                    .font(Metrics.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Arguing: \(badge.position)")
            }

            Spacer(minLength: 12)

            Text(badge.notice.isEmpty ? progress : badge.notice)
                .font(Metrics.captionFont)
                .foregroundStyle(badge.awaitingSend ? AnyShapeStyle(scheme.accentText)
                                                    : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .help(progress)

            if !badge.isOver {
                Toggle("Auto", isOn: $autoHandoff)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Glass.accent)
                    .help("Pass each arriving statement straight to this side, without pressing Send")
                    .accessibilityLabel("Automatic handover")
                Button("Skip turn", action: onSkip)
                    .buttonStyle(GlassButtonStyle())
                    .help("Offer the last statement to the other side again, when a debater has stopped answering")
                Button("End debate", action: onEnd)
                    .buttonStyle(GlassButtonStyle(tone: .danger))
                    .help("End both sides of this debate")
            }
        }
        .font(Metrics.captionFont)
        .padding(.horizontal, Metrics.outerPadding)
        .frame(height: 34)
        .background(Glass.accent.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Debate \(badge.roomID), \(badge.seatName)")
    }

    private var progress: String {
        badge.isOver
            ? "Debate over · \(badge.statementCount) statements"
            : "Statement \(badge.statementCount) of \(badge.maxStatements) · debate \(badge.roomID)"
    }
}
