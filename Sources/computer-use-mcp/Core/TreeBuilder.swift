// Walk an app window's accessibility tree into (a) a numbered, indented text
// outline for the model and (b) snapshot elements with locator paths.

import ApplicationServices
import Foundation

struct BuiltTree {
    let text: String
    let elements: [SnapshotElement]
}

let defaultMaxTreeElements = 500
private let maxDepth = 14
private let maxChildrenPerNode = 150
private let maxValueLength = 300

func buildTree(
    window: AXUIElement, windowOrigin: CGPoint, pixelsPerPoint: Double, generation: String,
    pathPrefix: [LocatorStep] = [], maxElements: Int = defaultMaxTreeElements
) -> BuiltTree {
    let maxNodes = max(1, min(maxElements, 5000))
    var lines: [String] = []
    var elements: [SnapshotElement] = []

    func pixelFrame(_ element: AXUIElement) -> [Double]? {
        guard let frame = axFrame(element) else { return nil }
        return [
            ((frame.origin.x - windowOrigin.x) * pixelsPerPoint).rounded(),
            ((frame.origin.y - windowOrigin.y) * pixelsPerPoint).rounded(),
            (frame.width * pixelsPerPoint).rounded(),
            (frame.height * pixelsPerPoint).rounded(),
        ]
    }

    func visit(_ element: AXUIElement, depth: Int, path: [LocatorStep]) {
        guard elements.count < maxNodes, depth <= maxDepth else { return }

        let role = axRole(element)
        let id = "e\(elements.count)@\(generation)"
        let label = axString(element, kAXTitleAttribute)
            ?? axString(element, kAXDescriptionAttribute)
            ?? axString(element, "AXPlaceholderValue")
        let frame = pixelFrame(element)

        elements.append(
            SnapshotElement(id: id, role: role, label: label, path: path, frame: frame ?? [0, 0, 0, 0])
        )
        lines.append(describeLine(element, id: id, role: role, label: label, frame: frame, depth: depth))

        let children = axElements(element, kAXChildrenAttribute)
        var roleCounts: [String: Int] = [:]
        for child in children.prefix(maxChildrenPerNode) {
            let childRole = axRole(child)
            let indexOfRole = roleCounts[childRole, default: 0]
            roleCounts[childRole] = indexOfRole + 1
            visit(child, depth: depth + 1, path: path + [LocatorStep(role: childRole, indexOfRole: indexOfRole)])
            if elements.count >= maxNodes { break }
        }
    }

    visit(window, depth: 0, path: pathPrefix)

    if elements.count >= maxNodes {
        lines.append(
            "… tree truncated at \(maxNodes) elements. Call get_app_state with scope_element_id "
                + "set to a container id to expand just that subtree, or raise max_elements."
        )
    }
    return BuiltTree(text: lines.joined(separator: "\n"), elements: elements)
}

private func describeLine(
    _ element: AXUIElement, id: String, role: String, label: String?, frame: [Double]?, depth: Int
) -> String {
    var parts: [String] = ["\(id) \(role)"]

    if let label, !label.isEmpty {
        parts.append("\"\(clean(label))\"")
    }
    if let frame {
        parts.append("(\(Int(frame[0])),\(Int(frame[1])),\(Int(frame[2])),\(Int(frame[3])))")
    }
    if let value = axString(element, kAXValueAttribute), !value.isEmpty {
        parts.append("value=\"\(clean(truncate(value)))\"")
    }
    if let selected = axString(element, kAXSelectedTextAttribute), !selected.isEmpty {
        parts.append("selected=\"\(clean(truncate(selected)))\"")
    }
    if axBool(element, kAXEnabledAttribute) == false {
        parts.append("disabled")
    }
    if axBool(element, kAXFocusedAttribute) == true {
        parts.append("focused")
    }
    if axBool(element, kAXSelectedAttribute) == true {
        parts.append("selected")
    }
    // Keep standard AX* actions; custom app actions often embed junk
    // (selector dumps, newlines) that pollutes the tree.
    let actions = axActionNames(element).filter { name in
        name.hasPrefix("AX") && name.allSatisfy { $0.isLetter || $0.isNumber }
    }
    if !actions.isEmpty {
        parts.append("actions=\(actions.map { String($0.dropFirst(2)) }.joined(separator: ","))")
    }

    return String(repeating: "\t", count: depth) + parts.joined(separator: " ")
}

private func truncate(_ value: String) -> String {
    value.count > maxValueLength ? String(value.prefix(maxValueLength)) + "…" : value
}

private func clean(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: " ")
}
