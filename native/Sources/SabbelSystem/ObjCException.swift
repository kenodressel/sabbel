import Foundation
import SabbelObjC

/// An Objective-C exception raised by a framework call, as a Swift error.
struct ObjCException: Error, CustomStringConvertible {
    let description: String
}

/// Runs `body`, turning an Objective-C exception it raises into a thrown
/// `ObjCException` instead of an abort (see `SabbelObjC.h`).
func catchingObjCException(_ body: () -> Void) throws {
    do {
        try SabbelObjC.catchingException(body)
    } catch {
        throw ObjCException(description: (error as NSError).localizedDescription)
    }
}
