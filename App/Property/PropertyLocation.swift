// App/Property/PropertyLocation.swift
import SwiftUI
import MapKit
import BudgetCore

// The property's address and its place on the map (Profile tab). The location is looked up with
// Apple Maps (`MKGeocodingRequest`) from the address text, once, when a changed address is saved or
// Find on map is pressed; the user can then move the pin by hand. The address text is the only thing
// sent, and only at the user's action. A snapshot build never looks anything up and draws a static
// placeholder instead of map tiles.

// MARK: - Lookup

/// Finds an address with Apple Maps and stores the result (one match), offers the matches (several),
/// or says it found nothing (none, offline, or an error).
@MainActor
final class PropertyLocator: ObservableObject {
    struct Candidate: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let coordinate: PropertyCoordinate
    }

    enum State: Equatable {
        case idle
        case searching
        /// Several places match: the user picks one (or places the pin).
        case choices(propertyId: Int64, [Candidate])
        case notFound
    }

    @Published private(set) var state: State = .idle
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?

    /// Looks `text` up and, with exactly one match, stores it as property `propertyId`'s location
    /// (`.lookedUp`) through `save`.
    func lookUp(_ text: String, propertyId: Int64, save: @escaping (Int64, PropertyCoordinate?, PropertyLocationSource) -> String?) {
        task?.cancel()
        state = .searching
        task = Task { [weak self] in
            let candidates: [Candidate]
            do {
                candidates = try await Self.geocode(text)
            } catch {
                candidates = []
            }
            guard let self, !Task.isCancelled else { return }
            switch candidates.count {
            case 0:
                self.state = .notFound
            case 1:
                self.errorMessage = save(propertyId, candidates[0].coordinate, .lookedUp)
                self.state = .idle
            default:
                self.state = .choices(propertyId: propertyId, candidates)
            }
        }
    }

    /// The user picked one of several matches.
    func choose(_ candidate: Candidate, save: (Int64, PropertyCoordinate?, PropertyLocationSource) -> String?) {
        guard case let .choices(propertyId, _) = state else { return }
        errorMessage = save(propertyId, candidate.coordinate, .lookedUp)
        state = .idle
    }

    func reset() {
        task?.cancel()
        task = nil
        state = .idle
        errorMessage = nil
    }

    /// The matches Apple Maps gives for `text`, without repeats of one place.
    private static func geocode(_ text: String) async throws -> [Candidate] {
        #if SNAPSHOTS
        // Snapshot builds never use the network.
        return []
        #else
        guard let request = MKGeocodingRequest(addressString: text) else { return [] }
        let items = try await request.mapItems
        var seen = Set<String>()
        return items.compactMap { item in
            let point = item.location.coordinate
            let coordinate = PropertyCoordinate(latitude: point.latitude, longitude: point.longitude)
            guard coordinate.isValid, seen.insert(String(format: "%.5f,%.5f", point.latitude, point.longitude)).inserted else { return nil }
            let title = item.address?.fullAddress ?? item.name ?? text
            return Candidate(title: title.replacingOccurrences(of: "\n", with: ", "), coordinate: coordinate)
        }
        #endif
    }
}

enum PropertyLocationFormat {
    /// "38.7223° N, 9.1393° W".
    static func coordinate(_ coordinate: PropertyCoordinate) -> String {
        let lat = String(format: "%.4f° %@", abs(coordinate.latitude), coordinate.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.4f° %@", abs(coordinate.longitude), coordinate.longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }

    /// The one-line note under the map: where the location came from.
    static func source(_ source: PropertyLocationSource?) -> String {
        switch source {
        case .adjusted: return "Location placed by hand on Apple Maps"
        case .lookedUp, nil: return "Location found with Apple Maps"
        }
    }

    static let privacyHelp = "Only the address text is sent to Apple Maps, and only when you save a changed address or press Find on map."
}

// MARK: - Address sheet

/// Edit address…: the street lines, postcode, city and country. Saved only on Save; a changed address is
/// then looked up on the map (`PropertyLocationPlan`), after asking when the pin was placed by hand.
struct PropertyAddressSheet: View {
    @ObservedObject var viewModel: PropertyViewModel
    let property: Property
    /// Called after the save with the text to look up, when the plan says to.
    let onLookUp: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address: PropertyAddress
    @State private var error: String?
    @State private var askingToReplace: String?
    @StateObject private var gate = FiledYearGate()

    init(viewModel: PropertyViewModel, property: Property, onLookUp: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.property = property
        self.onLookUp = onLookUp
        _address = State(initialValue: PropertyAddress(property))
    }

    var body: some View {
        form.filedYearGate(gate)
    }

    private var form: some View {
        SheetScaffold(title: "Edit address", subtitle: "Saving a changed address finds it on the map with Apple Maps.",
                      error: error, width: SheetMetrics.compactWidth, onCancel: { dismiss() },
                      primary: SheetAction("Save", action: save)) {
            SheetForm {
                LabeledContent("Street") {
                    TextField("Street", text: $address.lines, prompt: Text("Street and number, floor, door"), axis: .vertical)
                        .lineLimit(2...4)
                }
                LabeledContent("Postcode") {
                    TextField("Postcode", text: $address.postcode, prompt: Text("e.g. 1000-001")).frame(width: 120)
                }
                LabeledContent("City") { TextField("City", text: $address.city, prompt: Text("e.g. Lisboa")) }
                LabeledContent("Country") {
                    TextField("Country", text: $address.country, prompt: Text("PT")).frame(width: 60)
                        .sheetFieldNote("Two letters, e.g. PT: the property's country")
                }
            }
        }
        .confirmationDialog("Find the new address on the map?", isPresented: Binding(get: { askingToReplace != nil },
                                                                                     set: { if !$0 { askingToReplace = nil } })) {
            Button("Find the new address") {
                let text = askingToReplace
                commit(clearingLocation: false, lookUp: text)
            }
            Button("Keep my pin") { commit(clearingLocation: false, lookUp: nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You placed the pin by hand. Finding the new address with Apple Maps replaces it.")
        }
    }

    private func save() {
        let current = viewModel.property ?? property
        switch PropertyLocationPlan.plan(old: current, newAddress: address) {
        case .keep: commit(clearingLocation: false, lookUp: nil)
        case .clearLookedUp: commit(clearingLocation: true, lookUp: nil)
        // A looked-up pin belongs to the old address: it goes, and the new one is looked up.
        case .lookUp(let text): commit(clearingLocation: current.locationSource != .adjusted, lookUp: text)
        case .askBeforeReplacing(let text): askingToReplace = text
        }
    }

    private func commit(clearingLocation: Bool, lookUp: String?) {
        viewModel.saveAddress(address, of: viewModel.property ?? property, clearingLocation: clearingLocation, gate: gate) { result in
            switch result {
            case .success(let id):
                viewModel.onPropertiesChanged?(id)
                dismiss()
                if let lookUp { onLookUp(lookUp) }
            case .failure(let failure):
                error = PropertyMessages.text(for: failure)
            }
        }
    }
}

// MARK: - Map panel

/// The map with the property's pin: read-only, or, in Adjust location, a pin the user drags or places
/// with a click, saved only on Save location. Lookup results and failures show above the map.
struct PropertyMapPanel: View {
    @ObservedObject var viewModel: PropertyViewModel
    @ObservedObject var locator: PropertyLocator
    let property: Property

    @State private var adjusting = false
    @State private var pending: PropertyCoordinate?

    var body: some View {
        Panel("Map", fillsHeight: true) {
            accessory
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                status
                PropertyMapView(coordinate: adjusting ? pending : property.location, isAdjusting: adjusting,
                                country: property.country) { pending = $0 }
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                    .overlay {
                        if !adjusting, property.location == nil, locator.state != .searching {
                            Text(property.postalAddress.isEmpty ? "Add the address to find it on the map" : "No location yet")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                note
            }
        }
        .onChange(of: viewModel.propertyId) { _, _ in
            adjusting = false
            pending = nil
        }
    }

    @ViewBuilder private var accessory: some View {
        if adjusting {
            HStack(spacing: 8) {
                Button("Cancel") { adjusting = false; pending = nil }
                    .controlSize(.small)
                Button("Save location") { saveAdjusted() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(pending == nil || pending == property.location)
            }
        } else {
            HStack(spacing: 10) {
                if let text = property.postalAddress.searchText {
                    Button { findOnMap(text) } label: { Image(systemName: "magnifyingglass") }
                        .disabled(locator.state == .searching)
                        .help("Find on map: look the address up with Apple Maps")
                        .accessibilityLabel("Find on map")
                }
                Button {
                    pending = property.location
                    adjusting = true
                } label: {
                    Image(systemName: property.location == nil ? "mappin.and.ellipse" : "hand.point.up.left")
                }
                .help(property.location == nil ? "Place the property on the map by hand" : "Adjust location: drag the pin or click the map")
                .accessibilityLabel(property.location == nil ? "Place on map" : "Adjust location")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var status: some View {
        switch locator.state {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding the address with Apple Maps…").font(.callout).foregroundStyle(.secondary)
            }
        case .notFound:
            HStack(spacing: 6) {
                Label("Location not found — place it on the map", systemImage: "mappin.slash")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !adjusting {
                    Button("Place on map") { pending = property.location; adjusting = true }
                        .controlSize(.small)
                }
            }
        case let .choices(propertyId, candidates) where propertyId == property.id:
            VStack(alignment: .leading, spacing: 4) {
                Text("Several places match the address: pick one").font(.callout).foregroundStyle(.secondary)
                ForEach(candidates.prefix(5)) { candidate in
                    Button {
                        locator.choose(candidate, save: viewModel.setLocation)
                    } label: {
                        Label(candidate.title, systemImage: "mappin").lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help(candidate.title)
                }
            }
        case .choices:
            EmptyView()
        }
        if let message = locator.errorMessage {
            Text(message).font(.callout).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var note: some View {
        if adjusting {
            Text("Drag the pin or click the map, then Save location.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if let location = property.location {
            HStack(spacing: 6) {
                Text(PropertyLocationFormat.source(property.locationSource)).lineLimit(1)
                Text("·")
                Text(PropertyLocationFormat.coordinate(location)).monospacedDigit().figureText()
            }
            .font(.caption).foregroundStyle(.secondary)
            .help(PropertyLocationFormat.privacyHelp)
        } else {
            Text("Apple Maps finds it from the address text only")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(PropertyLocationFormat.privacyHelp)
        }
    }

    private func findOnMap(_ text: String) {
        guard let id = property.id else { return }
        locator.lookUp(text, propertyId: id, save: viewModel.setLocation)
    }

    private func saveAdjusted() {
        guard let id = property.id, let pending else { return }
        locator.errorMessage = viewModel.setLocation(propertyId: id, pending, source: .adjusted)
        if locator.errorMessage == nil {
            if case .notFound = locator.state { locator.reset() }
            if case .choices = locator.state { locator.reset() }
            adjusting = false
            self.pending = nil
        }
    }
}

// MARK: - Map

/// A MapKit map with the property's pin. Read-only unless `isAdjusting`: then it pans and zooms, a click
/// places the pin and the pin drags. A snapshot build draws `PropertyMapPlaceholder` instead (no tiles,
/// no network).
struct PropertyMapView: View {
    let coordinate: PropertyCoordinate?
    let isAdjusting: Bool
    let country: String
    var onPlace: (PropertyCoordinate) -> Void

    #if !SNAPSHOTS
    @State private var position: MapCameraPosition = .automatic
    @State private var dragStart: CGPoint?
    private static let space = "propertyMap"
    #endif

    var body: some View {
        #if SNAPSHOTS
        PropertyMapPlaceholder(coordinate: coordinate)
        #else
        MapReader { proxy in
            Map(position: $position, interactionModes: isAdjusting ? .all : []) {
                if let coordinate {
                    if isAdjusting {
                        Annotation("Property", coordinate: coordinate.clCoordinate, anchor: .bottom) {
                            Image(systemName: "mappin")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.red)
                                .shadow(radius: 1)
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    DragGesture(coordinateSpace: .named(Self.space))
                                        .onChanged { value in
                                            if dragStart == nil { dragStart = proxy.convert(coordinate.clCoordinate, to: .named(Self.space)) }
                                            guard let start = dragStart else { return }
                                            let point = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                                            if let moved = proxy.convert(point, from: .named(Self.space)) { onPlace(PropertyCoordinate(moved)) }
                                        }
                                        .onEnded { _ in dragStart = nil }
                                )
                                .accessibilityLabel("Property pin: drag to move it")
                        }
                    } else {
                        Marker("Property", systemImage: "house.fill", coordinate: coordinate.clCoordinate)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls { if isAdjusting { MapZoomStepper() } }
            .coordinateSpace(.named(Self.space))
            .onTapGesture(coordinateSpace: .named(Self.space)) { point in
                guard isAdjusting, let placed = proxy.convert(point, from: .named(Self.space)) else { return }
                onPlace(PropertyCoordinate(placed))
            }
        }
        .onAppear { position = Self.camera(for: coordinate, country: country) }
        .onChange(of: coordinate) { _, new in
            // Follows a stored location; while the pin is being placed the camera stays where the user put it.
            if !isAdjusting { position = Self.camera(for: new, country: country) }
        }
        .onChange(of: isAdjusting) { _, adjusting in
            if !adjusting { position = Self.camera(for: coordinate, country: country) }
        }
        .accessibilityLabel(coordinate.map { "Map: the property at \(PropertyLocationFormat.coordinate($0))" } ?? "Map: no location yet")
        #endif
    }

    #if !SNAPSHOTS
    private static func camera(for coordinate: PropertyCoordinate?, country: String) -> MapCameraPosition {
        if let coordinate {
            return .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 900, longitudinalMeters: 900))
        }
        // No location yet: the country when it's Portugal (the usual case), else the world.
        if country.uppercased() == "PT" {
            return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.6, longitude: -8.0),
                                              span: MKCoordinateSpan(latitudeDelta: 6.5, longitudeDelta: 6.5)))
        }
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 30, longitude: 0),
                                          span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)))
    }
    #endif
}

/// The map in a snapshot build: a drawn street grid with the pin, no tiles (the note below gives the coordinate).
struct PropertyMapPlaceholder: View {
    let coordinate: PropertyCoordinate?

    var body: some View {
        ZStack {
            Color.green.opacity(0.10)
            Canvas { context, size in
                var streets = Path()
                for step in stride(from: CGFloat(0.12), to: 1, by: 0.22) {
                    streets.move(to: CGPoint(x: 0, y: size.height * step))
                    streets.addLine(to: CGPoint(x: size.width, y: size.height * (step + 0.08)))
                    streets.move(to: CGPoint(x: size.width * step, y: 0))
                    streets.addLine(to: CGPoint(x: size.width * (step - 0.05), y: size.height))
                }
                context.stroke(streets, with: .color(.secondary.opacity(0.35)), lineWidth: 5)
            }
            if coordinate != nil {
                Image(systemName: "house.circle.fill").font(.system(size: 30)).foregroundStyle(.white, .red)
            }
        }
        .accessibilityLabel("Map placeholder")
    }
}

private extension PropertyCoordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
