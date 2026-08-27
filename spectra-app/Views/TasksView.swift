import SwiftUI
import SpectraCore

/// Tasks tab (spec §8): cross-profile live activity feed, newest first.
struct TasksView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Activity")
                        .padding(.horizontal, 24).padding(.top, 8)
                    ForEach(app.activityFeed) { item in
                        ActivityRow(item: item)
                    }
                    .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)  // fill width so
                .padding(.bottom, 20)                              // .paper() covers the
            }                                                      // whole screen, not just
            .paper()                                               // the narrow empty-feed column
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if app.activityFeed.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "circle.grid.2x2").font(.largeTitle).foregroundStyle(Theme.hairline)
                        Eyebrow("Nothing running")
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Eyebrow(item.profileName, color: Theme.muted)
                    Text(item.startedAt, format: .relative(presentation: .numeric))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted.opacity(0.7))
                }
                Text(item.toolName)
                    .font(Theme.serif(19))
                    .foregroundStyle(Theme.ink)
                Text(item.context)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(status: item.status)
                if let d = item.duration {
                    Text(String(format: "%.1fs", d))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
        .card()
    }
}

struct StatusPill: View {
    let status: ActivityItem.Status

    private var label: String {
        switch status {
        case .inProgress: return "In progress"
        case .inReview:   return "In review"
        case .success:    return "Success"
        case .failed:     return "Failed"
        }
    }
    private var color: Color {
        switch status {
        case .inProgress: return Theme.accent
        case .inReview:   return Theme.muted
        case .success:    return Theme.ok
        case .failed:     return Theme.danger
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label.uppercased())
                .font(Theme.mono(9, .semibold))
                .tracking(1)
                .foregroundStyle(color)
        }
        .padding(.vertical, 5).padding(.horizontal, 9)
        .background(color.opacity(0.1), in: Capsule())
    }
}
