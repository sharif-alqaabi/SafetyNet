import Foundation

struct HomeProfile: Codable, Equatable {
    var personName: String
    var address: String
    var room: String
    var contactName: String
    var contactNumber: String
    var bloodThinners: Bool
    var homeCode: String

    static let demo = HomeProfile(
        personName: "Mary",
        address: "14 Oak Street",
        room: "kitchen",
        contactName: "Alex",
        contactNumber: "+15555550100",
        bloodThinners: false,
        homeCode: "OAK-14"
    )
}

enum DeviceRole: String, CaseIterable, Identifiable {
    case hub
    case family

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hub: return "Home hub"
        case .family: return "Family"
        }
    }
}
