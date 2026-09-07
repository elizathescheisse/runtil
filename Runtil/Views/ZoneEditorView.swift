import SwiftUI
import RuntilCore

/// Zone editor supporting all three models.
///
/// Whichever method is selected, the resulting BPM ranges are always shown underneath — the
/// point of offering three models is undermined if you can't see what each one does to your
/// actual numbers. Switching methods preserves whatever inputs carry over.
struct ZoneEditorView: View {
    @Binding var zones: HeartRateZones

    @State private var method: MethodChoice = .percentMax
    @State private var maxHR: Int = 185
    @State private var restingHR: Int = 60
    @State private var age: Int = 35
    @State private var edges: [Int] = [100, 120, 140, 160, 175, 190]

    enum MethodChoice: String, CaseIterable, Identifiable {
        case direct = "Direct"
        case percentMax = "% of max"
        case karvonen = "Karvonen"
        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .direct:
                return "Type your zone boundaries directly. Use this if you have numbers from a lab test or a coach."
            case .percentMax:
                return "Zones as percentages of your maximum heart rate. The standard model."
            case .karvonen:
                return "Uses heart rate reserve — the gap between resting and max. More personalized, but needs an accurate resting heart rate."
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Method", selection: $method) {
                    ForEach(MethodChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(method.explanation)
            }

            switch method {
            case .direct:
                Section("Zone boundaries") {
                    ForEach(edges.indices, id: \.self) { index in
                        Stepper(
                            "\(label(forEdge: index)): \(edges[index]) bpm",
                            value: Binding(
                                get: { edges[index] },
                                set: { newValue in
                                    edges[index] = newValue
                                    // Keep the boundaries monotonic, or the zones become
                                    // nonsense the moment one crosses its neighbour.
                                    for i in (index + 1)..<edges.count where edges[i] < edges[i - 1] {
                                        edges[i] = edges[i - 1]
                                    }
                                    for i in stride(from: index - 1, through: 0, by: -1) where edges[i] > edges[i + 1] {
                                        edges[i] = edges[i + 1]
                                    }
                                }
                            ),
                            in: 40...230
                        )
                    }
                }

            case .percentMax:
                Section("Max heart rate") {
                    Stepper("\(maxHR) bpm", value: $maxHR, in: 120...230)
                    Stepper("Estimate from age: \(age)", value: $age, in: 10...100)
                    Button("Use estimate (\(HeartRateZones.tanakaMaxHR(age: age)) bpm)") {
                        maxHR = HeartRateZones.tanakaMaxHR(age: age)
                    }
                    .font(.callout)
                }

            case .karvonen:
                Section("Inputs") {
                    Stepper("Max: \(maxHR) bpm", value: $maxHR, in: 120...230)
                    Stepper("Resting: \(restingHR) bpm", value: $restingHR, in: 30...120)
                }
            }

            Section {
                ForEach(1...5, id: \.self) { zone in
                    ZoneRow(zone: zone, range: preview.range(forZone: zone))
                }
            } header: {
                Text("Resulting zones")
            } footer: {
                Text("Zone 2 is the easy aerobic range most run/walk plans target.")
            }
        }
        .navigationTitle("Zones")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadFromBinding)
        .onChange(of: preview) { _, newValue in zones = newValue }
    }

    /// What the current inputs produce, recomputed live as you change them.
    private var preview: HeartRateZones {
        switch method {
        case .direct: return HeartRateZones(method: .direct(edges: edges))
        case .percentMax: return HeartRateZones(method: .percentMax(maxHR: maxHR))
        case .karvonen: return HeartRateZones(method: .karvonen(maxHR: maxHR, restingHR: restingHR))
        }
    }

    /// Seed the controls from whatever the plan already had, so opening the editor and
    /// switching methods starts from your real numbers rather than defaults.
    private func loadFromBinding() {
        switch zones.method {
        case .direct(let existing):
            method = .direct
            edges = existing
        case .percentMax(let existingMax, _):
            method = .percentMax
            maxHR = existingMax
            edges = zones.edges
        case .karvonen(let existingMax, let existingResting, _):
            method = .karvonen
            maxHR = existingMax
            restingHR = existingResting
            edges = zones.edges
        }
    }

    private func label(forEdge index: Int) -> String {
        index == 5 ? "Top of Z5" : "Bottom of Z\(index + 1)"
    }
}

private struct ZoneRow: View {
    let zone: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text("Zone \(zone)")
                .fontWeight(zone == 2 ? .semibold : .regular)
            Spacer()
            Text("\(range.lowerBound)–\(range.upperBound) bpm")
                .foregroundStyle(zone == 2 ? .primary : .secondary)
                .monospacedDigit()
        }
    }
}
