import SwiftUI

/// One request: where it stands, and -- while it waits for one -- every lossless copy found
/// on Soulseek, to pick from. Watched every few seconds while it is open.
struct RequestDetailView: View {
    @Environment(AppState.self) private var appState

    let requestID: String
    /// Called once a copy is picked, for the Add sheet to close itself.
    var onStarted: () -> Void = {}

    @State private var request: SonicClient.GrabRequest?
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        List {
            if let request {
                Section {
                    GrabRequestRow(request: request)
                }
                ForEach(request.targets) { target in
                    if target.state == .choosing, !target.copies.isEmpty {
                        Section {
                            ForEach(target.copies) { copy in
                                Button {
                                    Task { await choose(target, copy) }
                                } label: {
                                    CopyRow(copy: copy, isBest: copy.index == 0)
                                }
                                .buttonStyle(.plain)
                                .disabled(isWorking)
                            }
                        } header: {
                            Text(request.targets.count > 1 ? target.title : "Pick a Copy")
                        } footer: {
                            Text("Lossless only, best first: whole, free to send now, and quick.")
                        }
                    } else if request.targets.count > 1 {
                        Section(target.kind == "album" ? "Album" : "Song") {
                            TargetRow(target: target)
                        }
                    }
                }
                actions(request)
            } else if error == nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(request?.title ?? "Request")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: requestID) { await watch() }
    }

    @ViewBuilder
    private func actions(_ request: SonicClient.GrabRequest) -> some View {
        if request.state == .failed || request.state == .cancelled {
            Button("Try Again", systemImage: "arrow.clockwise") {
                Task { await act { try await appState.grab.retry(request) } }
            }
        }
        if request.state.isActive || request.state == .choosing {
            Button("Cancel Request", systemImage: "xmark.circle", role: .destructive) {
                Task { await act { try await appState.grab.cancel(request) } }
            }
        }
    }

    private func watch() async {
        while !Task.isCancelled {
            if let fresh = await appState.grab.details(requestID) {
                request = fresh
                error = nil
            } else if request == nil {
                error = "The server isn't answering."
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func choose(_ target: SonicClient.GrabTarget, _ copy: SonicClient.GrabCopy) async {
        guard let request else { return }
        await act {
            self.request = try await appState.grab.choose(request, target: target.key, copy: copy.index)
            onStarted()
        }
    }

    private func act(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            error = nil
            request = await appState.grab.details(requestID) ?? request
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A request in a list: what, where it stands, and how far its download has got.
struct GrabRequestRow: View {
    let request: SonicClient.GrabRequest

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.itemSpacing) {
            RequestStateIcon(state: request.state)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.title ?? "")
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text([request.artist, request.kind == "album" ? "Album" : "Song",
                      request.library == .music ? "Music" : "My Music"].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(request.detail)
                    .font(.footnote)
                    .foregroundStyle(request.state == .failed ? .red : .secondary)
                if let progress = request.progress, request.state == .downloading {
                    ProgressView(value: progress.fraction)
                        .tint(Color.appTint)
                    Text("\(byteText(progress.done)) of \(byteText(progress.total))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct TargetRow: View {
    let target: SonicClient.GrabTarget

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.itemSpacing) {
            RequestStateIcon(state: target.state)
            VStack(alignment: .leading, spacing: 3) {
                Text(target.title).font(.body.weight(.medium))
                Text(target.detail).font(.footnote).foregroundStyle(target.state == .failed ? .red : .secondary)
                if let progress = target.progress, target.state == .downloading {
                    ProgressView(value: progress.fraction).tint(Color.appTint)
                }
            }
        }
    }
}

struct RequestStateIcon: View {
    let state: SonicClient.GrabState

    var body: some View {
        Group {
            switch state {
            case .searching, .queued, .importing:
                ProgressView()
            case .downloading:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.appTint)
            case .choosing:
                Image(systemName: "list.bullet.circle.fill").foregroundStyle(Color.appTint)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
        }
        .font(.title3)
        .frame(width: 28, height: 28)
        .accessibilityLabel(state.rawValue.capitalized)
    }
}

/// One sharer's copy: its folder, how much, what format, and how soon it would come.
private struct CopyRow: View {
    let copy: SonicClient.GrabCopy
    let isBest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(copy.folder)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if isBest {
                    Text("Best")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appTint.opacity(0.2), in: Capsule())
                        .foregroundStyle(Color.appTint)
                }
            }
            Text([copy.formats.map { $0.uppercased() }.joined(separator: ", "),
                  copy.tracks == 1 ? "1 file" : "\(copy.tracks) files", byteText(copy.bytes)].joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(availability)
                .font(.footnote)
                .foregroundStyle(copy.free == true ? .green : .secondary)
            Text(copy.peer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var availability: String {
        let speed = (copy.speed ?? 0) > 0 ? " · \(byteText(Int64(copy.speed ?? 0)))/s" : ""
        if copy.free == true { return "Free to send now" + speed }
        let queue = copy.queue ?? 0
        return (queue > 0 ? "\(queue) waiting before you" : "Busy") + speed
    }
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
