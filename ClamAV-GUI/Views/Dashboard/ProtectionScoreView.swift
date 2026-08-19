import SwiftUI

struct ProtectionScoreView: View {
    let score: ProtectionScore
    let onAction: (ScoreComponent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(score.score)")
                    .font(.system(size: 54, weight: .bold))
                Text("Protection Score")
                    .font(.headline)
                Spacer()
            }

            ForEach(score.components) { component in
                HStack {
                    Image(systemName: component.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(component.isComplete ? .green : .secondary)
                    Text(component.title)
                    Spacer()
                    if component.action != nil {
                        Button("Fix") { onAction(component) }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}
