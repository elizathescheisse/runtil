import SwiftUI
import RuntilCore

/// Start and run a plan on the phone, no watch required.
struct PhoneRunView: View {
    @Bindable var library: PlanLibrary
    @Bindable var controller: PhoneWorkoutController
    @Bindable var mirror: MirroredWorkoutObserver

    var body: some View {
        NavigationStack {
            Group {
                // A run on the wrist wins the screen: the watch owns the session, and
                // showing the plan list underneath it would invite starting a second one.
                if let mirrored = mirror.state, mirror.isActive {
                    MirroredRunView(
                        state: mirrored,
                        isActive: true,
                        spokenCuesEnabled: Binding(
                            get: { mirror.spokenCuesEnabled },
                            set: { mirror.spokenCuesEnabled = $0 }
                        )
                    )
                } else {
                    switch controller.state {
                    case .idle:
                        PlanPickerView(library: library, controller: controller, mirror: mirror)
                    case .finished:
                        RunSummaryView(controller: controller)
                    case .failed(let message):
                        ContentUnavailableView("Couldn't start", systemImage: "exclamationmark.triangle", description: Text(message))
                    default:
                        ActiveRunView(controller: controller)
                    }
                }
            }
            .navigationTitle("runtil")
            .onAppear { mirror.refreshAvailability() }
        }
    }
}

// MARK: - Choosing a plan

private struct PlanPickerView: View {
    @Bindable var library: PlanLibrary
    @Bindable var controller: PhoneWorkoutController
    @Bindable var mirror: MirroredWorkoutObserver

    var body: some View {
        List {
            if let imported = library.importedProfile {
                ImportNotice(profile: imported, zones: library.plans.first?.zones) {
                    library.dismissImportNotice()
                }
            }

            Section {
                ForEach(library.plans) { plan in
                    Button {
                        Task { await controller.start(plan: plan) }
                    } label: {
                        HStack(spacing: 12) {
                            // Leading, so it reads as "press play on this one" rather than
                            // as a status badge trailing the row. Always occupies the slot
                            // so the names stay aligned whether a plan is runnable or not.
                            //
                            // Outline means available; solid is kept for a run in progress.
                            Image(systemName: "play.circle")
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
                                // Points at the route that's actually open. Someone with a
                                // watch isn't blocked at all — they're just on the wrong
                                // device, which "needs heart rate" fails to tell them.
                                if mirror.availability == .ready {
                                    Label("Start on watch", systemImage: "applewatch")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .labelStyle(.titleAndIcon)
                                } else {
                                    Label("Needs heart rate", systemImage: "heart.slash")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .labelStyle(.titleAndIcon)
                                }
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
                Text("Tap a plan to start tracking. Editing plans happens in the Plans tab.\n\nTime, distance and pace work on their own. Heart-rate plans need a live reading — either a paired Bluetooth monitor, or start the plan from the runtil watch app, which has the sensor on your wrist.")
            }

            Section {
                LabeledContent {
                    Text(mirror.availability.statusText)
                        .foregroundStyle(mirror.availability == .ready ? .green : .secondary)
                } label: {
                    Label("Apple Watch", systemImage: "applewatch")
                }
                if let explanation = mirror.availability.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    HeartRateMonitorView(monitor: controller.monitor)
                } label: {
                    LabeledContent {
                        Text(controller.monitor.state.description)
                            .foregroundStyle(controller.monitor.state.isConnected ? .green : .secondary)
                    } label: {
                        Label("Bluetooth monitor", systemImage: "sensor.tag.radiowaves.forward")
                    }
                }

                // Plans are pushed automatically on every edit, but a push can miss its
                // moment if the session wasn't ready — so there's a way to ask again
                // rather than the two devices quietly disagreeing.
                Button {
                    library.syncNow()
                } label: {
                    LabeledContent {
                        if let pushed = library.lastPushedAt {
                            Text(pushed.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("Send plans to watch", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                if let problem = library.lastSyncProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Heart rate source")
            } footer: {
                Text("Either one unlocks heart-rate plans — you don't need both.\n\n**Apple Watch:** start the plan on your watch. It runs the session, buzzes your wrist, and appears here live.\n\n**Bluetooth monitor:** a chest strap or armband paired to your phone. Start the plan here, and cues come through your headphones.")
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

                if controller.plan?.advisories.paceTarget != nil {
                    Button {
                        controller.cues.paceCuesMuted.toggle()
                    } label: {
                        Label(
                            controller.cues.paceCuesMuted ? "Pace off" : "Mute pace",
                            systemImage: controller.cues.paceCuesMuted ? "speaker.slash.fill" : "speaker.wave.2"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(controller.cues.paceCuesMuted ? .orange : .accentColor)
                }
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

/// Says what was filled in from Health, rather than changing the numbers you're about to
/// train against without mentioning it.
private struct ImportNotice: View {
    let profile: HealthProfileImporter.Profile
    let zones: HeartRateZones?
    let onDismiss: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Zones set from Health", systemImage: "heart.text.square")
                    .font(.subheadline.weight(.semibold))

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let zone2 = zones?.range(forZone: 2) {
                    Text("Zone 2: \(zone2.lowerBound)–\(zone2.upperBound) bpm")
                        .font(.caption.weight(.medium))
                }

                Text("Check these in Plans → Heart rate zones. A recorded maximum is only as high as something you've actually hit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Got it", action: onDismiss)
                    .font(.caption)
            }
            .padding(.vertical, 2)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let max = profile.observedMaxHeartRate { parts.append("max \(max) (recorded)") }
        else if let max = profile.bestMaxHeartRate { parts.append("max \(max) (estimated)") }
        if let resting = profile.restingHeartRate { parts.append("resting \(resting)") }
        if let age = profile.age { parts.append("age \(age)") }
        return parts.joined(separator: " · ")
    }
}
