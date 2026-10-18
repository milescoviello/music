import SwiftUI

/// Packing music for a trip.
///
/// This screen exists because the honest answer to "download some music for the flight" is
/// arithmetic: at the library's own quality, five days is about 54 GB. Rather than let
/// someone find that out one album at a time, the numbers are shown up front — including
/// how much of the trip is already on the phone, which is usually more than expected.
struct TripModeView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(DownloadCenter.self) private var downloads

    @State private var model = TripModeModel()
    @State private var didStart = false

    var body: some View {
        Form {
            Section("How long") {
                Stepper("\(model.days) \(model.days == 1 ? "day" : "days")", value: $model.days, in: 1...21)
                Stepper(
                    "\(model.hoursPerDay) \(model.hoursPerDay == 1 ? "hour" : "hours") a day",
                    value: $model.hoursPerDay,
                    in: 1...12
                )
                LabeledContent("Music needed", value: model.targetText)
            }

            Section {
                Picker("Quality", selection: $model.quality) {
                    ForEach(DownloadQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.quality.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Quality")
            } footer: {
                // The trade, stated rather than implied.
                Text("Original is what this app normally downloads. The other three are transcoded by the server on the way out, which is the only way a long trip fits.")
            }

            planSection

            if !model.plan.groups.isEmpty {
                Section {
                    ForEach(model.plan.groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).lineLimit(1)
                            Text("\(group.songs.count) songs\(group.subtitle.map { " · \($0)" } ?? "")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("What gets packed")
                }
            }
        }
        .navigationTitle("Trip Mode")
        .playerClearance()
        .overlay {
            if model.isLoading, model.groups.isEmpty { ProgressView() }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            await model.load(appState: appState, scope: scope.scope)
        }
        // Re-planning is pure arithmetic on already-fetched songs, so it can run on every
        // change of the steppers without touching the network.
        .onChange(of: model.days) { model.replan(downloads: downloads) }
        .onChange(of: model.hoursPerDay) { model.replan(downloads: downloads) }
        .onChange(of: model.quality) { model.replan(downloads: downloads) }
        .onChange(of: downloads.catalog.entries.count) { model.replan(downloads: downloads) }
    }

    @ViewBuilder
    private var planSection: some View {
        Section {
            LabeledContent("Songs", value: "\(model.plan.songCount)")
            LabeledContent("Playing time", value: model.plan.seconds.asLongDuration)
            LabeledContent("Already downloaded", value: "\(model.plan.alreadyCount) songs")
            LabeledContent("To download", value: model.plan.bytesToDownload.asFileSize)
            LabeledContent("Free space", value: model.freeBytes.asFileSize)

            if model.plan.isSpaceLimited {
                Label(
                    "Some of it was left out — there isn't room at this quality.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            Button {
                model.pack(appState: appState)
            } label: {
                Label(
                    model.plan.toDownload.isEmpty
                        ? "Already packed"
                        : "Download \(model.plan.toDownload.count) songs",
                    systemImage: "arrow.down.circle.fill"
                )
            }
            .disabled(model.plan.toDownload.isEmpty)
        } header: {
            Text("The plan")
        } footer: {
            Text("Built from your favourites, today's mixes and what you play most — whole albums where it can, and never the same recording twice.")
        }
    }
}
