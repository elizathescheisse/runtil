import SwiftUI
import WidgetKit

/// Watch face complication: a one-tap way into a run.
///
/// Deliberately a launcher rather than a live readout. Showing the current segment on the
/// face would need a shared container between the app and this extension, and App Groups
/// aren't available under free provisioning — but it would also be redundant, since watchOS
/// returns you to the running workout app when you raise your wrist.
struct RuntilComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RuntilLauncher", provider: LauncherProvider()) { _ in
            LauncherView()
                .widgetURL(URL(string: "runtil://start"))
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("runtil")
        .description("Start a coached run.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

struct LauncherEntry: TimelineEntry {
    let date: Date
}

/// Nothing to schedule — the complication never changes, so one entry that never expires
/// keeps it off the system's refresh budget entirely.
struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry {
        LauncherEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "figure.run")
                    .font(.title3)
            }

        case .accessoryCorner:
            Image(systemName: "figure.run")
                .font(.title2)
                .widgetLabel("runtil")

        case .accessoryInline:
            Label("runtil", systemImage: "figure.run")

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("runtil", systemImage: "figure.run")
                    .font(.headline)
                Text("Start a coached run")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        default:
            Image(systemName: "figure.run")
        }
    }
}
