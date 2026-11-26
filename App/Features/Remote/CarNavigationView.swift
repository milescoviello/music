import SwiftUI

/// Where the car should take you: search Apple Maps or pick a recent place, and the car's
/// own map shows the route and the turns. The car's Destination page offers the same recents.
struct CarNavigationView: View {
    @State private var query = ""
    @State private var hits: [CarNavigation.Hit] = []
    @State private var searching = false

    private var nav: CarNavigation { CarNavigation.shared }
    private var position: CarLocation { CarLocation.shared }

    var body: some View {
        Form {
            Group {
                if let route = nav.route {
                    Section("Navigating") {
                        LabeledContent(route.destination, value: summary(route))
                        ForEach(Array(route.steps.prefix(6).enumerated()), id: \.offset) { _, step in
                            Text(step.text).font(.subheadline)
                        }
                        Button("Stop", role: .destructive) { nav.stop() }
                    }
                }

                Section {
                    TextField("Search Maps", text: $query)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if searching { ProgressView() }
                    ForEach(hits) { hit in
                        Button { Task { _ = await nav.start(hit) } } label: { row(hit.name, hit.address) }
                    }
                } header: {
                    Text("Where to?")
                } footer: {
                    if let problem = nav.problem { Text(problem) }
                }

                if !nav.recents.isEmpty {
                    Section("Recent") {
                        ForEach(nav.recents) { place in
                            Button { Task { _ = await nav.start(place) } } label: { row(place.title, place.subtitle) }
                                .swipeActions { Button("Forget", role: .destructive) { nav.forget(place) } }
                        }
                    }
                }

                Section {
                    Toggle("Send My Position to the Car", isOn: Binding(get: { position.enabled }, set: { position.enabled = $0 }))
                    if position.enabled {
                        LabeledContent("Location", value: permission)
                        if position.authorization == .notDetermined || position.authorization == .authorizedWhenInUse {
                            Button(position.authorization == .notDetermined ? "Allow Location" : "Allow in the Background") {
                                position.askPermission()
                            }
                        } else if position.authorization == .denied || position.authorization == .restricted {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        if position.running {
                            LabeledContent("Sending", value: position.lastSent.map { "last \($0.formatted(date: .omitted, time: .standard))" } ?? "starting")
                        }
                    }
                } header: {
                    Text("Position")
                } footer: {
                    Text("The car's own GPS belongs to its navigation, so its map uses this iPhone's position. It's sent only while the car is connected. \"Always\" lets it start with the app in the background, which is how it usually is in the car.")
                }

                Section {
                } footer: {
                    Text("Apple Maps works out the route from this iPhone. The car shows it on its own map with the next turn and your arrival time, and asks for a new route if you leave it. The car's Destination page lists these recent places too.")
                }
            }
            .glassRow()
        }
        .disabled(nav.isRouting)
        .navigationTitle("Navigate in the Car")
        .onAppear { nav.prepare() }
    }

    private var permission: String {
        switch position.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While Using the App"
        case .denied: "Not Allowed"
        case .restricted: "Restricted"
        default: "Not Asked Yet"
        }
    }

    private func row(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.primary)
            if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func summary(_ route: RemoteCarRoute) -> String {
        let miles = route.distance / 1609.344
        let minutes = Int((route.time / 60).rounded(.up))
        return String(format: "%.1f mi · %d min", miles, minutes)
    }

    private func search() async {
        searching = true
        hits = await nav.search(query)
        searching = false
    }
}
