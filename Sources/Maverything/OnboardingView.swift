import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Grant Full Disk Access")
                .font(.title2).bold()

            Text("""
            To search **every** file — system files, hidden files, and other apps' \
            data that Spotlight ignores — Maverything needs Full Disk Access. \
            Without it, results are limited to files your account can already read.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 440)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Click **Open Settings** below")
                step(2, "Turn on **Maverything** in the Full Disk Access list (drag the app in if it isn't listed)")
                step(3, "Come back and click **I've granted access**")
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                Button("Open Settings") { model.openFDASettings() }
                    .keyboardShortcut(.defaultAction)
                Button("I've granted access") { model.recheckFullDiskAccess() }
                Button("Continue without") { model.showOnboarding = false }
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 540)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint.opacity(0.15)))
            Text(.init(text))
        }
    }
}
