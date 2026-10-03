import SwiftUI

/// Presents a factual readiness or scan outcome, without implying overall protection.
struct ScanOverviewStatusView: View {
    let status: ScanOverviewStatus
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(status.title)
                    .font(.title2.weight(.semibold))
                Text(status.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = status.actionTitle {
                    Button(title, action: onAction)
                        .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("overview-readiness-status")
    }
}

extension ScanOverviewStatus {
    var tint: Color {
        switch kind {
        case .scanning, .updating: return .accentColor
        case .setupNeeded, .definitionsNeeded, .incomplete: return .orange
        case .detections: return .red
        case .ready: return .secondary
        }
    }
}
