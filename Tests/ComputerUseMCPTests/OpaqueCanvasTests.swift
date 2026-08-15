import Testing

@testable import computer_use_mcp

private let windowSize: [Double] = [1000, 800]

private func canvasNode(_ id: Int, role: String, frame: [Double]) -> CapturedNode {
    CapturedNode(id: "e\(id)@s1", role: role, label: nil, frame: frame)
}

private func richShell(
    canvasRole: String = "AXGroup", canvasFrame: [Double] = [0, 100, 1000, 700],
    canvasHasChild: Bool = false
) -> [CapturedNode] {
    let window = canvasNode(0, role: "AXWindow", frame: [0, 0, 1000, 800])
    let toolbar = canvasNode(1, role: "AXToolbar", frame: [0, 0, 1000, 100])
    toolbar.appendChild(canvasNode(2, role: "AXButton", frame: [10, 10, 80, 80]))
    toolbar.appendChild(canvasNode(3, role: "AXButton", frame: [100, 10, 80, 80]))
    let canvas = canvasNode(4, role: canvasRole, frame: canvasFrame)
    if canvasHasChild {
        canvas.appendChild(canvasNode(5, role: "AXStaticText", frame: [10, 110, 200, 20]))
    }
    window.appendChild(toolbar)
    window.appendChild(canvas)
    return [window, toolbar] + toolbar.children + [canvas] + canvas.children
}

@Suite struct OpaqueCanvasTests {
    @Test func childlessDominantElementIsFlagged() {
        let hint = opaqueCanvasHint(elements: richShell(), windowSize: windowSize)
        #expect(hint?.contains("e4@s1") == true)
        #expect(hint?.contains("ocr:true") == true)
    }

    @Test func dominantElementWithChildrenIsNotFlagged() {
        #expect(opaqueCanvasHint(
            elements: richShell(canvasHasChild: true), windowSize: windowSize) == nil)
    }

    @Test func treeWithWebAreaIsNotFlagged() {
        #expect(opaqueCanvasHint(
            elements: richShell(canvasRole: "AXWebArea"), windowSize: windowSize) == nil)
        let elements = richShell() + [canvasNode(6, role: "AXWebArea", frame: [0, 0, 10, 10])]
        #expect(opaqueCanvasHint(elements: elements, windowSize: windowSize) == nil)
    }

    @Test func subThresholdAndRootAreNotFlagged() {
        #expect(opaqueCanvasHint(
            elements: richShell(canvasFrame: [0, 100, 1000, 400]),
            windowSize: windowSize) == nil)
        #expect(opaqueCanvasHint(
            elements: [canvasNode(0, role: "AXWindow", frame: [0, 0, 1000, 800])],
            windowSize: windowSize) == nil)
    }

    @Test func oversizedFrameIsClippedToWindow() {
        #expect(opaqueCanvasHint(
            elements: richShell(canvasFrame: [-500, -500, 3000, 3000]),
            windowSize: windowSize) != nil)
        #expect(opaqueCanvasHint(
            elements: richShell(canvasFrame: [0, 500, 1000, 2400]),
            windowSize: windowSize) == nil)
    }
}
