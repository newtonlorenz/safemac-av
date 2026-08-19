import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Set Up ClamAV")
                .font(.title)
            Text("Configure paths, update signatures, and run your first scan.")
                .foregroundColor(.secondary)
            Button("Done") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(width: 420)
    }
}
