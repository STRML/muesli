import AppKit
import ApplicationServices
import Foundation

/// Reads the text on a call page through the Accessibility API. Design and failure matrix:
/// docs/call-roster.md.
enum CallRosterReader {
    /// Texts longer than this are sentences (chat, captions), never a name.
    private static let maxTextLength = 60
    private static let maxNodes = 4_000
    private static let maxDepth = 40

    /// The page's text, or nil when nothing could be read: no Accessibility access, the browser has no
    /// window, or the call is not the page in front. Only a page whose URL is the followed room is
    /// ever read, so an unrelated tab's text cannot reach the roster.
    static func read(
        processIdentifier: pid_t,
        roomURL: String,
        budget: TimeInterval = 1.5
    ) -> [CallRosterTextNode]? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.4)
        // Chromium keeps the page out of the accessibility tree until a client says it needs it.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let deadline = Date().addingTimeInterval(budget)
        guard let page = webArea(in: app, showing: roomURL, deadline: deadline) else { return nil }
        var nodes: [CallRosterTextNode] = []
        collectText(from: page, ancestry: [], into: &nodes, deadline: deadline)
        return nodes
    }

    private static func webArea(in app: AXUIElement, showing roomURL: String, deadline: Date) -> AXUIElement? {
        var visited = 0
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < maxDepth, visited < maxNodes, Date() < deadline else { return nil }
            visited += 1
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                return pageURL(of: element).flatMap(MeetingURLNormalizer.normalize)?.url == roomURL ? element : nil
            }
            for child in children(of: element) {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        for window in elements(app, kAXWindowsAttribute) {
            if let found = search(window, depth: 0) { return found }
        }
        return nil
    }

    private static func collectText(
        from element: AXUIElement,
        ancestry: [String],
        into nodes: inout [CallRosterTextNode],
        deadline: Date
    ) {
        guard ancestry.count < maxDepth, nodes.count < maxNodes, Date() < deadline else { return }
        if string(element, kAXRoleAttribute) == "AXStaticText",
           let text = string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute),
           !text.isEmpty, text.count <= maxTextLength {
            nodes.append(CallRosterTextNode(text: text, ancestry: ancestry))
        }
        let classes = (attribute(element, "AXDOMClassList") as? [String])?.joined(separator: " ") ?? ""
        for child in children(of: element) {
            collectText(from: child, ancestry: ancestry + [classes], into: &nodes, deadline: deadline)
        }
    }

    private static func pageURL(of element: AXUIElement) -> String? {
        guard let value = attribute(element, "AXURL") else { return nil }
        return (value as? URL)?.absoluteString ?? (value as? String)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute)
    }
}
