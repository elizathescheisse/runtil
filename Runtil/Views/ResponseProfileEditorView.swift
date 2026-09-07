import SwiftUI
import RuntilCore

/// Editor for how *your* heart responds to effort.
///
/// These numbers vary enough between people that a fixed default would be wrong for most
/// of them — so each is exposed, with an explanation of what changing it actually does.
struct ResponseProfileEditorView: View {
    @Binding var profile: HRResponseProfile

    var body: some View {
        Form {
            Section {
                Stepper(value: $profile.lagSeconds, in: 0...90, step: 1) {
                    LabeledContent("Response lag") {
                        Text("\(Int(profile.lagSeconds))s")
                            .monospacedDigit()
                    }
                }
                LagPresets(profile: $profile)
            } header: {
                Text("Heart rate lag")
            } footer: {
                Text("How long your heart rate takes to reflect a change in effort. runtil watches how fast your heart rate is climbing and projects it forward by this much, so a hard climb buzzes you earlier than a gentle drift. After a run, the summary shows what it actually measured and offers to update this.")
            }

            Section {
                Stepper(value: $profile.approachMargin, in: 0...20) {
                    LabeledContent("Buffer") { Text("\(profile.approachMargin) bpm") }
                }
            } header: {
                Text("How close is close enough")
            } footer: {
                Text("Switches you this far before the actual zone edge. Larger keeps you further inside the zone.")
            }

            Section {
                Stepper(value: $profile.confirmSamples, in: 1...10) {
                    LabeledContent("Confirm over") { Text("\(profile.confirmSamples) readings") }
                }
                Stepper(value: $profile.cooldown, in: 10...180, step: 5) {
                    LabeledContent("Quiet period") { Text("\(Int(profile.cooldown))s") }
                }
            } header: {
                Text("Noise control")
            } footer: {
                Text("Heart rate readings jump around. Requiring several in a row stops a single spike from sending you walking, and the quiet period keeps a warning from repeating the whole way up a hill.")
            }

            Section {
                Toggle("Set minimum myself", isOn: Binding(
                    get: { profile.minSegmentDuration != nil },
                    set: { profile.minSegmentDuration = $0 ? profile.effectiveMinSegmentDuration : nil }
                ))
                if let minimum = profile.minSegmentDuration {
                    Stepper(value: Binding(
                        get: { minimum },
                        set: { profile.minSegmentDuration = $0 }
                    ), in: 10...300, step: 5) {
                        LabeledContent("Minimum segment") { Text(Format.duration(minimum)) }
                    }
                } else {
                    LabeledContent("Minimum segment") {
                        Text("\(Format.duration(profile.effectiveMinSegmentDuration)) (auto)")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $profile.maxSegmentDuration, in: 60...1800, step: 30) {
                    LabeledContent("Maximum segment") { Text(Format.duration(profile.maxSegmentDuration)) }
                }
            } header: {
                Text("Segment limits")
            } footer: {
                Text("The minimum stops run/walk flapping when your heart rate sits right on the boundary; left on auto it tracks your lag. The maximum makes sure a heart rate that never reaches the target can't leave you running indefinitely.")
            }
        }
        .navigationTitle("Response")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Starting points for people who have no idea what to enter — which is most people,
/// the first time.
private struct LagPresets: View {
    @Binding var profile: HRResponseProfile

    private let presets: [(String, TimeInterval, String)] = [
        ("Fast", 15, "Well trained, responds quickly"),
        ("Typical", 25, "Most recreational runners"),
        ("Slow", 40, "Beta blockers, heat, or low fitness")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { name, seconds, _ in
                    Button(name) { profile.lagSeconds = seconds }
                        .buttonStyle(.bordered)
                        .tint(profile.lagSeconds == seconds ? .accentColor : .secondary)
                }
            }
            if let match = presets.first(where: { $0.1 == profile.lagSeconds }) {
                Text(match.2)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
