import Foundation

/// A Sonos group (or a standalone room, which is just a group of one).
/// `id` is the coordinator's UDN-less UUID, stable for the lifetime of the grouping.
struct SonosGroup: Equatable, Identifiable {
    let id: String
    let coordinatorIP: String
    /// Coordinator first, then the other members sorted by name - the order `displayName`
    /// reads in, and the order the editor lists rooms in.
    let members: [SonosRoom]

    var coordinator: SonosRoom? { members.first { $0.uuid == id } }

    /// "Living Room + Kitchen + Office", coordinator first.
    var displayName: String {
        members.map(\.name).joined(separator: " + ")
    }

    var isStandalone: Bool { members.count == 1 }
}
