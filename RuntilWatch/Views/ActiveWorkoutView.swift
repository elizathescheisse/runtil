import SwiftUI
import RuntilCore

/// The screen you don't look at.
///
/// Everything important is delivered through haptics — this exists for the moments you do
/// glance down, and for the cue log that makes the engine observable in the simulator.
struct ActiveWorkoutView: View {
    let controller: WorkoutController
    let store: PlanStore

    @Environment(\.dismiss) private var dismiss
    @State private var page = Page.initialPage

    enum Page {
        case controls, metrics, log

        /// `-page log` opens straight to the cue log, for driving the app from the command
        /// line where there's no way to swipe.
        static var initialPage: Page {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-page"),
                  arguments.indices.contains(index + 1)
            else { return .metrics }
            switch arguments[index + 1] {
            case "log": return .log
            case "controls": return .controls
            default: return .metrics
            }
        }
    }

    var body: some View {
        Group {
            switch controller.state {
            case .finished:
                SummaryView(controller: controller, store: store, onDone: close)
            case .failed(let title, let message):
                FailureView(title: title, message: message, onDone: close)
            default:
                TabView(selection: $page) {
                    ControlsPage(controller: controller, onEnd: { Task { await controller.finish() } })
                        .tag(Page.controls)
                    MetricsPage(controller: controller)
                        .tag(Page.metrics)
                    CueLogPage(controller: controller)
                        .tag(Page.log)
                }
                .tabViewStyle(.verticalPage)
            }
        }
    }

    private func close() {
        controller.reset()
        dismiss()
    }
}

// MARK: - Metrics

private struct MetricsPage: View {
    let controller: WorkoutController

    private var units: DistanceUnit { controller.plan?.units ?? .miles }

    var body: some View {
        // While a change of effort is being asked for, the whole page is the instruction.
        // A haptic phrase only means something once you've learned it; one word read at
        // arm's length means something the first time. The numbers are one swipe away and
        // nobody needs them in the two seconds after a buzz.
        if controller.isPromptingEffortChange {
            EffortPrompt(kind: controller.currentSegment?.kind ?? .run)
        } else {
            metrics
        }
    }

    private var metrics: some View {
        // Scrolls so a small watch, a long plan name or a large text size can never clip
        // the numbers off the edge — this is the screen you glance at mid-stride.
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                SegmentBanner(controller: controller)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(controller.heartRate.map(String.init) ?? "--")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.pink)
                    Text("bpm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // The projection is what the engine actually decides on, so it earns
                    // its place beside the raw number.
                    if let projected = controller.projectedHeartRate,
                       let actual = controller.heartRate,
                       abs(projected - actual) >= 2 {
                        Text("→ \(projected)")
                            .font(.caption2)
                            .foregroundStyle(.pink.opacity(0.8))
                    }
                }

                Divider()

                LabeledContent("Distance") {
                    Text(Format.distance(meters: controller.distance, unit: units))
                }
                LabeledContent("Pace") {
                    Text(Format.pace(secondsPerMeter: controller.rollingPace, unit: units))
                }
                LabeledContent("Elapsed") {
                    Text(Format.duration(controller.elapsed))
                }

                if controller.isMirroringToPhone {
                    Label("Phone", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
            }
            .font(.caption)
            .padding(.horizontal, 2)
        }
    }
}

/// One word, as large as the watch will draw it.
///
/// Deliberately holds nothing else: this appears in the seconds right after a haptic
/// phrase, when the only question is "run or walk?" and it should be answerable from a
/// glance with the arm still swinging.
private struct EffortPrompt: View {
    let kind: SegmentKind

    @State private var emphasised = false

    var body: some View {
        // Two-word kinds stack rather than shrink — "WARM UP" over two lines stays as
        // legible at arm's length as "RUN" does on one.
        Text(kind.displayName.uppercased().replacingOccurrences(of: " ", with: "\n"))
            .font(.system(size: 60, weight: .black, design: .rounded))
            .multilineTextAlignment(.center)
            .lineSpacing(-8)
            .minimumScaleFactor(0.45)
            .lineLimit(2)
            .foregroundStyle(kind.isEffort ? Color.green : Color.orange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // A slow pulse says the instruction is still outstanding — it stops when your
            // pace confirms the change and this view is replaced by the metrics.
            .opacity(emphasised ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: emphasised)
            .onAppear { emphasised = true }
            .accessibilityLabel(Text(kind.displayName))
    }
}

/// What you're meant to be doing right now, and how long you've been doing it.
private struct SegmentBanner: View {
    let controller: WorkoutController

    var body: some View {
        HStack {
            Text(controller.currentSegment?.kind.displayName.uppercased() ?? "—")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)

            Spacer()

            if let remaining = controller.timeRemainingInSegment {
                Text(Format.duration(remaining))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text(Format.duration(controller.timeInSegment))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        (controller.currentSegment?.kind.isEffort ?? true) ? .green : .orange
    }
}

// MARK: - Controls

private struct ControlsPage: View {
    let controller: WorkoutController
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(role: .destructive, action: onEnd) {
                    Label("End", systemImage: "stop.circle.fill")
                }
                Button {
                    controller.state == .paused ? controller.resume() : controller.pause()
                } label: {
                    Label(
                        controller.state == .paused ? "Resume" : "Pause",
                        systemImage: controller.state == .paused ? "play.fill" : "pause.fill"
                    )
                }
            }
            .labelStyle(.iconOnly)
            .font(.title3)

            Button {
                controller.skipSegment()
            } label: {
                Label("Next segment", systemImage: "forward.end.fill")
                    .font(.caption)
            }

            Toggle("Haptics", isOn: Binding(
                get: { controller.haptics.hapticsEnabled },
                set: { controller.haptics.hapticsEnabled = $0 }
            ))
            .font(.caption)

            // Only worth showing when the plan can actually produce pace cues.
            if controller.plan?.advisories.paceTarget != nil {
                Toggle("Mute pace", isOn: Binding(
                    get: { controller.haptics.paceCuesMuted },
                    set: { controller.haptics.paceCuesMuted = $0 }
                ))
                .font(.caption)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Cue log

/// In the simulator `WKInterfaceDevice.play` does nothing, so this list is the only
/// evidence the engine is working. It stays on a real watch too — useful for checking
/// after a run why something buzzed when it did.
private struct CueLogPage: View {
    let controller: WorkoutController

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if controller.haptics.log.isEmpty {
                    Text("No cues yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.haptics.log) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(Format.duration(entry.elapsed))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.summary)
                                .font(.system(size: 12, weight: .medium))
                            Text(entry.haptic)
                                .font(.system(size: 10))
                                .foregroundStyle(entry.played ? .green : .secondary)
                        }
                        Spacer()
                        // Dropped cues are shown, not hidden — collisions are exactly the
                        // thing worth being able to see.
                        if !entry.played {
                            Image(systemName: "speaker.slash")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id(entry.id)
                }
            }
            .navigationTitle("Cues")
            .onChange(of: controller.haptics.log.count) {
                if let last = controller.haptics.log.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

// MARK: - Terminal states

private struct FailureView: View {
    let title: String
    let message: String
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("OK", action: onDone)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
    }
}
