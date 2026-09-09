import SwiftUI
import RuntilCore

/// Start and run a plan on the phone, no watch required.
struct PhoneRunView: View {
    @Bindable var library: PlanLibrary
    @Bindable var controller: PhoneWorkoutController

    var body: some View {
        NavigationStack {
            Group {
                switch controller.state {
                case .idle:
                    PlanPickerView(library: library, controller: controller)
                case .finished:
                    RunSummaryView(controller: controller)
                case .failed(let message):
                    ContentUnavailableView("Couldn't start", systemImage: "exclamationmark.triangle", description: Text(message))
                default:
                    ActiveRunView(controller: controller)
                }
            }
            .navigationTitle("Run")
        }
    }
}

// MARK: - Choosing a plan

private struct PlanPickerView: View {
    @Bindable var library: PlanLibrary
    @Bindable var controller: PhoneWorkoutController

    var body: some View {
        List {
            Section {
                ForEach(library.plans) { plan in
                    Button {
                        Task { await controller.start(plan: plan) }
                    } label: {
                        HStack(spacing: 12) {
                            // Leading, so it reads as "press play on this one" rather than
                            // as a status badge trailing the row. Always occupies the slot
                            // so the names stay aligned whether a plan is runnable or not.
                            Image(systemName: "play.circle.fill")
                                .font(.title)
                                .foregroundStyle(controller.canRun(plan) ? .green : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.name)
                                Text(plan.driveMode.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            if !controller.canRun(plan) {
                                // Names what's missing rather than prescribing one fix —
                                // the plan needs a heart rate from somewhere.
                                Label("Needs heart rate", systemImage: "heart.slash")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.canRun(plan))
                }
            } header: {
                Text("Start a run")
            } footer: {
                Text("Tap a plan to start tracking. Editing plans happens in the Plans tab.\n\nTime, distance and pace work on their own. Heart-rate plans need a live reading from a paired Bluetooth monitor — a chest strap, an armband, or anything else that broadcasts heart rate. An Apple Watch can't feed heart rate to your phone fast enough to cue you, so run those plans from the watch app instead.")
            }

            Section("Heart rate") {
                NavigationLink {
                    HeartRateMonitorView(monitor: controller.monitor)
                } label: {
                    LabeledContent("Monitor") {
                        Text(controller.monitor.state.description)
                            .foregroundStyle(controller.monitor.state.isConnected ? .green : .secondary)
                    }
                }
            }

            Section {
                Toggle("Spoken cues", isOn: Binding(
                    get: { controller.cues.spokenCuesEnabled },
                    set: { controller.cues.spokenCuesEnabled = $0 }
                ))
                Toggle("Tones", isOn: Binding(
                    get: { controller.cues.tonesEnabled },
                    set: { controller.cues.tonesEnabled = $0 }
                ))
                Toggle("Vibration", isOn: Binding(
                    get: { controller.cues.hapticsEnabled },
                    set: { controller.cues.hapticsEnabled = $0 }
                ))
            } header: {
                Text("Cues")
            } footer: {
                Text("Audio keeps working with the screen off and your phone in a pocket. Vibration is reliable while the app is open, but iOS may stop it once the screen locks — so keep audio on if you can't watch the screen.")
            }
        }
    }
}

// MARK: - Running

private struct ActiveRunView: View {
    @Bindable var controller: PhoneWorkoutController

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(controller.currentSegment?.kind.displayName.uppercased() ?? "—")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle((controller.currentSegment?.kind.isEffort ?? true) ? .green : .orange)

                if let remaining = controller.timeRemainingInSegment {
                    Text(Format.duration(remaining))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text(Format.duration(controller.timeInSegment))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 20)

            HStack(spacing: 0) {
                Metric(title: "Distance",
                       value: Format.distance(meters: controller.distance, unit: controller.plan?.units ?? .miles))
                Metric(title: "Pace",
                       value: Format.pace(secondsPerMeter: controller.rollingPace, unit: controller.plan?.units ?? .miles))
                Metric(title: "Heart",
                       value: controller.heartRate.map { "\($0)" } ?? "—")
            }

            Text(Format.duration(controller.elapsed))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 14) {
                Button {
                    controller.state == .paused ? controller.resume() : controller.pause()
                } label: {
                    Label(controller.state == .paused ? "Resume" : "Pause",
                          systemImage: controller.state == .paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    controller.skipSegment()
                } label: {
                    Label("Skip", systemImage: "forward.end.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                Task { await controller.finish() }
            } label: {
                Text("End run").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - After

private struct RunSummaryView: View {
    @Bindable var controller: PhoneWorkoutController

    var body: some View {
        List {
            Section("This run") {
                LabeledContent("Time") { Text(Format.duration(controller.elapsed)) }
                LabeledContent("Distance") {
                    Text(Format.distance(meters: controller.distance, unit: controller.plan?.units ?? .miles))
                }
                if let engine = controller.engine {
                    LabeledContent("Laps") { Text("\(engine.cycle)") }
                }
            }

            Section("Cues") {
                ForEach(controller.cues.log) { entry in
                    HStack {
                        Text(Format.duration(entry.elapsed))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.summary)
                            .font(.callout)
                        Spacer()
                        if !entry.played {
                            Image(systemName: "speaker.slash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button("Done") { controller.reset() }
        }
    }
}
