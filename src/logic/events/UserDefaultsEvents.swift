import Cocoa

class UserDefaultsEvents: NSObject {
    private static var isObserving = false

    static func observe() {
        guard !isObserving else { return }
        isObserving = true
    }
}
