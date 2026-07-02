import Testing

@testable import computer_use_mcp

// A rich-shell window: toolbar with buttons plus one dominant content child.
// Window is 1000x800 (=800_000 px²), so the 1000x700 canvas covers 87.5%.

private func step(_ role: String, _ index: Int = 0) -> LocatorStep {
    LocatorStep(role: role, indexOfRole: index)
}

private func element(
    _ id: Int, role: String, path: [LocatorStep], frame: [Double]
) -> SnapshotElement {
    SnapshotElement(id: "e\(id)@s1", role: role, label: nil, path: path, frame: frame)
}

private let windowSize: [Double] = [1000, 800]

private func richShell(canvasRole: String = "AXGroup", canvasFrame: [Double] = [0, 100, 1000, 700])
    -> [SnapshotElement]
{
    [
        element(0, role: "AXWindow", path: [], frame: [0, 0, 1000, 800]),
        element(1, role: "AXToolbar", path: [step("AXToolbar")], frame: [0, 0, 1000, 100]),
        element(2, role: "AXButton", path: [step("AXToolbar"), step("AXButton", 0)], frame: [10, 10, 80, 80]),
        element(3, role: "AXButton", path: [step("AXToolbar"), step("AXButton", 1)], frame: [100, 10, 80, 80]),
        element(4, role: canvasRole, path: [step("AXGroup")], frame: canvasFrame),
    ]
}

@Suite struct OpaqueCanvasTests {
    @Test func childlessDominantElementIsFlagged() {
        let hint = opaqueCanvasHint(elements: richShell(), windowSize: windowSize)
        #expect(hint != nil)
        #expect(hint!.contains("e4@s1"))
        #expect(hint!.contains("(AXGroup)"))
        #expect(hint!.contains("ocr:true"))
    }

    @Test func dominantElementWithChildrenIsNotFlagged() {
        let elements =
            richShell() + [
                element(
                    5, role: "AXStaticText", path: [step("AXGroup"), step("AXStaticText")],
                    frame: [10, 110, 200, 20])
            ]
        #expect(opaqueCanvasHint(elements: elements, windowSize: windowSize) == nil)
    }

    @Test func treeWithWebAreaIsNotFlagged() {
        // Invisible web content has its own opt-in-and-rebuild recourse; a
        // big childless web area must not be misdiagnosed as a canvas.
        var elements = richShell(canvasRole: "AXWebArea")
        #expect(opaqueCanvasHint(elements: elements, windowSize: windowSize) == nil)
        // A web area anywhere in the tree suppresses the hint too.
        elements = richShell() + [
            element(5, role: "AXWebArea", path: [step("AXWebArea")], frame: [0, 0, 10, 10])
        ]
        #expect(opaqueCanvasHint(elements: elements, windowSize: windowSize) == nil)
    }

    @Test func subThresholdCoverageIsNotFlagged() {
        // 1000x400 = 50% of the window: below the 60% bar.
        let elements = richShell(canvasFrame: [0, 100, 1000, 400])
        #expect(opaqueCanvasHint(elements: elements, windowSize: windowSize) == nil)
    }

    @Test func windowRootIsExcluded() {
        // A childless window root is the sparse-tree case, not a canvas.
        let elements = [element(0, role: "AXWindow", path: [], frame: [0, 0, 1000, 800])]
        #expect(opaqueCanvasHint(elements: elements, windowSize: windowSize) == nil)
    }

    @Test func missingOrDegenerateWindowSizeIsNotFlagged() {
        #expect(opaqueCanvasHint(elements: richShell(), windowSize: nil) == nil)
        #expect(opaqueCanvasHint(elements: richShell(), windowSize: [0, 800]) == nil)
        #expect(opaqueCanvasHint(elements: richShell(), windowSize: [1000]) == nil)
    }

    @Test func oversizedFrameIsClippedToWindow() {
        // Only the on-window part counts, but a frame larger than the window
        // still qualifies at 100% visible coverage.
        let elements = richShell(canvasFrame: [-500, -500, 3000, 3000])
        let hint = opaqueCanvasHint(elements: elements, windowSize: windowSize)
        #expect(hint != nil)
        #expect(hint!.contains("e4@s1"))
        // A frame mostly hanging off-window does not qualify: 1000x2400 tall
        // strip with only 1000x300 visible = 37.5%.
        let offWindow = richShell(canvasFrame: [0, 500, 1000, 2400])
        #expect(opaqueCanvasHint(elements: offWindow, windowSize: windowSize) == nil)
    }

    @Test func largestQualifyingElementWins() {
        // Two stacked childless layers over the threshold: name the bigger.
        let elements =
            richShell(canvasFrame: [0, 100, 1000, 640]) + [
                element(5, role: "AXImage", path: [step("AXImage")], frame: [0, 100, 1000, 700])
            ]
        let hint = opaqueCanvasHint(elements: elements, windowSize: windowSize)
        #expect(hint != nil)
        #expect(hint!.contains("e5@s1"))
        #expect(hint!.contains("(AXImage)"))
    }
}
