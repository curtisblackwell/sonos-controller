import Foundation

/// A Sonos group (or a standalone room, which is just a group of one).
/// `id` is the coordinator's UDN-less UUID, stable for the lifetime of the grouping.
struct SonosGroup: Equatable {
    let id: String
    let displayName: String
    let coordinatorIP: String
}
