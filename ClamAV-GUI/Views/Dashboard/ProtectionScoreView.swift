import SwiftUI

struct ProtectionScoreView: View {
    let score: ProtectionScore
    @EnvironmentObject var appState: AppState
    let onAction: (ScoreComponent) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Gauge(value: Double(score.score), in: 0...100) {
                    Text("Protection")
                } currentValueLabel: {
                    Text("\(score.score)")
                        .font(.title2.weight(.bold))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(scoreColor.gradient)
                .scaleEffect(1.45)
                .frame(width: 104, height: 104)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Protection Score")
                        .font(.headline)
                    Text(scoreSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(spacing: 7) {
                ForEach(score.components) { component in
                    HStack(spacing: 10) {
                        Image(systemName: component.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundColor(component.isComplete ? .green : .secondary)
                            .frame(width: 18)

                        Text(component.title)
                            .font(.subheadline)

                        Spacer()

                        if component.action != nil {
                            if isUpdating(component) {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Updating...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Button("Review") { onAction(component) }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(22)
        .adaptiveGlassSurface(tint: scoreColor.opacity(0.08), cornerRadius: 26)
        .accessibilityElement(children: .contain)
    }

    private var scoreColor: Color {
        switch score.score {
        case 80...: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    private var scoreSummary: String {
        switch score.score {
        case 80...: return "Your Mac is well protected"
        case 50..<80: return "A few items need attention"
        default: return "Security setup needs attention"
        }
    }

    private func isUpdating(_ component: ScoreComponent) -> Bool {
        component.action == .updateSignatures && appState.isUpdatingSignatures
    }
}
