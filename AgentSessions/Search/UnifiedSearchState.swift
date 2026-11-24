import Foundation
import Combine

final class UnifiedSearchState: ObservableObject {
    @Published var query: String = ""
    @Published var autoJumpSessionID: String? = nil
    @Published var autoJumpToken: Int = 0
    /// Text the jump should land on (the start of the result's excerpt), when known.
    var autoJumpAnchor: String? = nil

    func requestAutoJump(sessionID: String?, anchor: String? = nil) {
        autoJumpAnchor = anchor
        autoJumpSessionID = sessionID
        autoJumpToken &+= 1
    }
}
