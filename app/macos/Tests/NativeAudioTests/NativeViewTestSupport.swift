import AppKit

/// Shared support for hidden production-view tests. Fixtures and behavior
/// assertions remain in their workflow suites.
@MainActor enum NativeViewTestSupport {
    static func element(_ root: Any, identifier: String) -> NSObject? {
        guard let node = root as? NSObject else { return nil }
        if node.responds(to: NSSelectorFromString("accessibilityIdentifier")),
           node.value(forKey: "accessibilityIdentifier") as? String == identifier { return node }
        // SwiftUI virtual AX nodes expose Objective-C accessibility methods
        // without necessarily conforming to NSAccessibilityProtocol.
        for child in (node as AnyObject).accessibilityChildren?() ?? [] {
            if let found = element(child, identifier: identifier) { return found }
        }
        return nil
    }

    static func settle(_ host: NSView) async {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
