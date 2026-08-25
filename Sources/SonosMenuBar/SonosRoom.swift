import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A single controllable Sonos room. Bonded satellites (rears, subs) and invisible members
/// like a Boost are filtered out during topology parsing, so every room here is something
/// the user can meaningfully group, ungroup, and send transport commands to.
struct SonosRoom: Equatable, Identifiable, Hashable, Codable {
    /// The player's RINCON UUID - this is what `x-rincon:` join URIs refer to, and what a
    /// group uses as its coordinator identity.
    let uuid: String
    let name: String
    let ipAddress: String

    var id: String { uuid }
}

/// Drag payload for moving a room between groups in the editor. The identifier is declared
/// in Info.plist under UTExportedTypeDeclarations; it is app-internal and has no file form.
extension UTType {
    static let sonosRoom = UTType(exportedAs: "com.curtis.sonos-controller.room")
}

extension SonosRoom: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sonosRoom)
    }
}
