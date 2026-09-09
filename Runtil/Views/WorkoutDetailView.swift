import SwiftUI
import Charts
import HealthKit
import CoreLocation
import RuntilCore

/// Everything about one finished run.
///
/// Reads back from HealthKit rather than keeping a private copy, so it shows the same run
/// Fitness does and can't drift out of sync with it.
struct WorkoutDetailView: View {
    let workout: HKWorkout
    let zones: HeartRateZones

    @State private var loader = WorkoutDetailLoader()
    @State private var effort: Double = 5
    @State private var effortSaved = false

    private var unit: DistanceUnit { .miles }

    var body: some View {
        List {
            summarySection

            if !loader.zoneTimes.isEmpty {
                zoneSection
            }
            if !loader.heartRateSamples.isEmpty {
                heartRateChart
            }
            if !loader.splits.isEmpty {
                paceChart
                splitsSection
            }
            if !loader.altitudes.isEmpty {
                elevationChart
            }

            effortSection
        }
        .navigationTitle(workout.startDate.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.load(workout: workout, zones: zones) }
    }

    // MARK: Summary

    private var summarySection: some View {
        Section {
            LabeledContent("Duration") { Text(Format.duration(workout.duration)) }
            if let meters = loader.totalDistance {
                LabeledContent("Distance") { Text(Format.distance(meters: meters, unit: unit)) }
                LabeledContent("Average pace") {
                    Text(Format.pace(secondsPerMeter: workout.duration / meters, unit: unit))
                }
            }
            if let calories = loader.activeCalories {
                LabeledContent("Active calories") {
                    // A number in kcal means little on its own; a familiar equivalent
                    // gives it a size you can feel.
                    Text("\(Int(calories)) kcal · \(FoodEquivalent.describe(calories))")
                }
            }
            if let average = loader.averageHeartRate, let peak = loader.maxHeartRate {
                LabeledContent("Heart rate") { Text("\(average) avg · \(peak) max") }
            }
            if let gain = loader.elevationGain {
                LabeledContent("Elevation gain") { Text("\(Int(gain)) m") }
            }
            if let weather = loader.weather {
                LabeledContent("Conditions") {
                    Text("\(Int(weather.temperatureCelsius))°C · \(Int(weather.relativeHumidity * 100))% humidity")
                }
                // Dew point, not humidity, is what predicts a slowdown — so it gets the
                // plain-language verdict next to it rather than being left as a number.
                LabeledContent("Dew point") {
                    Text("\(Int(weather.effectiveDewPointCelsius.rounded()))°C · \(weather.comfort.label)")
                        .foregroundStyle(Self.comfortColor(weather.comfort))
                }
                Text(weather.comfort.effect)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Zones

    private var zoneSection: some View {
        Section("Time in zones") {
            Chart(loader.zoneTimes) { entry in
                BarMark(
                    x: .value("Time", entry.seconds),
                    y: .value("Zone", entry.zone == 0 ? "Below" : "Z\(entry.zone)")
                )
                .foregroundStyle(Self.zoneColor(entry.zone))
                .annotation(position: .trailing) {
                    Text(Format.duration(entry.seconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(loader.zoneTimes.count) * 32 + 20)
        }
    }

    private var heartRateChart: some View {
        Section("Heart rate") {
            Chart {
                // Zone 2 shaded behind the trace, so "was I in the right range" is
                // answered by looking rather than by reading numbers off an axis.
                let z2 = zones.range(forZone: 2)
                RectangleMark(
                    yStart: .value("Zone 2 low", z2.lowerBound),
                    yEnd: .value("Zone 2 high", z2.upperBound)
                )
                .foregroundStyle(.green.opacity(0.12))

                ForEach(loader.heartRateSamples, id: \.elapsed) { sample in
                    LineMark(
                        x: .value("Time", sample.elapsed / 60),
                        y: .value("BPM", sample.bpm)
                    )
                    .foregroundStyle(.pink)
                    .interpolationMethod(.monotone)
                }
            }
            .chartXAxisLabel("minutes")
            .frame(height: 180)
        }
    }

    private var paceChart: some View {
        Section("Pace by split") {
            Chart(loader.splits) { split in
                BarMark(
                    x: .value("Split", split.index),
                    y: .value("Pace", split.secondsPerMeter * unit.metersPerUnit / 60)
                )
                .foregroundStyle(split.isPartial ? Color.secondary : Color.accentColor)
            }
            .chartYAxisLabel("min/\(unit.abbreviation)")
            .frame(height: 160)
        }
    }

    private var splitsSection: some View {
        Section("Splits") {
            ForEach(loader.splits) { split in
                HStack {
                    Text(split.isPartial ? "Final" : "\(split.index)")
                        .frame(width: 44, alignment: .leading)
                        .foregroundStyle(split.isPartial ? .secondary : .primary)
                    Text(Format.pace(secondsPerMeter: split.secondsPerMeter, unit: unit))
                        .monospacedDigit()
                    Spacer()
                    if let bpm = split.averageHeartRate {
                        Text("\(bpm) bpm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var elevationChart: some View {
        Section("Elevation") {
            Chart(Array(loader.altitudes.enumerated()), id: \.offset) { index, altitude in
                AreaMark(
                    x: .value("Sample", index),
                    y: .value("Metres", altitude)
                )
                .foregroundStyle(.brown.opacity(0.3))
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Metres", altitude)
                )
                .foregroundStyle(.brown)
            }
            .chartXAxis(.hidden)
            .frame(height: 140)
        }
    }

    // MARK: RPE

    private var effortSection: some View {
        Section {
            if let existing = loader.effortScore {
                LabeledContent("Effort") { Text("\(Int(existing))/10") }
            } else if effortSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("How hard did that feel?")
                        Spacer()
                        Text("\(Int(effort))/10").monospacedDigit().bold()
                    }
                    Slider(value: $effort, in: 1...10, step: 1)
                    Text(Self.effortLabel(Int(effort)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Save effort") {
                        Task {
                            await loader.saveEffort(effort, for: workout)
                            effortSaved = true
                        }
                    }
                }
            }
        } header: {
            Text("Perceived effort")
        } footer: {
            Text("Saved to Health as a workout effort score, so it sits alongside the run rather than only inside runtil.")
        }
    }

    private static func effortLabel(_ value: Int) -> String {
        switch value {
        case 1...2: return "Very easy — could do this all day"
        case 3...4: return "Easy — full conversation"
        case 5...6: return "Moderate — short sentences"
        case 7...8: return "Hard — a few words at a time"
        default: return "Maximal — couldn't speak"
        }
    }

    static func comfortColor(_ comfort: RunningComfort) -> Color {
        switch comfort {
        case .ideal, .comfortable: return .green
        case .noticeable: return .yellow
        case .uncomfortable: return .orange
        case .difficult, .oppressive: return .red
        }
    }

    static func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 0: return .gray
        case 1: return .blue
        case 2: return .green
        case 3: return .yellow
        case 4: return .orange
        default: return .red
        }
    }
}

/// Turns kilocalories into something with a size you can picture.
enum FoodEquivalent {
    private static let foods: [(name: String, kcal: Double)] = [
        ("banana", 105), ("slice of toast", 90), ("flat white", 120),
        ("chocolate digestive", 85), ("bagel", 250), ("slice of pizza", 285),
        ("burrito", 620)
    ]

    static func describe(_ calories: Double) -> String {
        guard calories > 40 else { return "a mouthful" }
        // Pick the food giving a count between 1 and 6, so it stays imaginable.
        let best = foods.min { first, second in
            abs(calories / first.kcal - 2.5) < abs(calories / second.kcal - 2.5)
        }
        guard let best else { return "" }
        let count = max(1, Int((calories / best.kcal).rounded()))
        return count == 1 ? "about a \(best.name)" : "about \(count) \(best.name)s"
    }
}
