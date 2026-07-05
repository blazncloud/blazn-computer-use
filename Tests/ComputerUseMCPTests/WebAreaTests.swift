import Testing

@testable import computer_use_mcp

private func element(_ id: Int, role: String, path: [LocatorStep], label: String? = nil) -> SnapshotElement {
    SnapshotElement(id: "e\(id)@s1", role: role, label: label, path: path, frame: [0, 0, 10, 10])
}

private let group0 = LocatorStep(role: "AXGroup", indexOfRole: 0)
private let web0 = LocatorStep(role: "AXWebArea", indexOfRole: 0)

@Suite struct WebAreaTests {
    @Test func webAreaWithContentIsNotEmpty() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXWebArea", path: [group0, web0]),
            element(2, role: "AXStaticText", path: [group0, web0, group0, LocatorStep(role: "AXStaticText", indexOfRole: 0)]),
        ]
        #expect(!hasEmptyWebArea(elements))
    }

    @Test func childlessWebAreaIsEmpty() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXWebArea", path: [group0, web0]),
            element(2, role: "AXButton", path: [LocatorStep(role: "AXButton", indexOfRole: 0)]),
        ]
        #expect(hasEmptyWebArea(elements))
    }

    @Test func trailingWebAreaIsEmpty() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXWebArea", path: [group0, web0]),
        ]
        #expect(hasEmptyWebArea(elements))
    }

    @Test func treeWithoutWebAreaIsNotEmpty() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXButton", path: [LocatorStep(role: "AXButton", indexOfRole: 0)]),
        ]
        #expect(!hasEmptyWebArea(elements))
    }

    @Test func coldStartWebAreaTriggersBoundedRetryPlan() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXWebArea", path: [group0, web0]),
        ]
        #expect(hasColdStartWebContentShape(elements))
        let backoff = webMaterializationRetryBackoff(coldStartShape: hasColdStartWebContentShape(elements))
        #expect(!backoff.isEmpty)
        #expect(backoff.reduce(0, +) <= 2_500)
    }

    @Test func childlessWKWebViewPlaceholderTriggersBoundedRetryPlan() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXGroup", path: [group0], label: "web-pane"),
        ]
        #expect(hasColdStartWebContentShape(elements))
        #expect(!webMaterializationRetryBackoff(coldStartShape: true).isEmpty)
    }

    @Test func warmWebTreeDoesNotTriggerRetryPlan() {
        let elements = [
            element(0, role: "AXWindow", path: []),
            element(1, role: "AXWebArea", path: [group0, web0]),
            element(2, role: "AXStaticText", path: [group0, web0, LocatorStep(role: "AXStaticText", indexOfRole: 0)]),
        ]
        #expect(!hasColdStartWebContentShape(elements))
        #expect(webMaterializationRetryBackoff(coldStartShape: hasColdStartWebContentShape(elements)).isEmpty)
    }

    @Test func exhaustedWebMaterializationNoteIsHonest() {
        let note = webContentNotMaterializedNote()
        #expect(note.contains("has not materialized"))
        #expect(note.contains("returned tree is current"))
        #expect(note.contains("ocr:true"))
    }

    @Test func snapshotAncestryDetectsTargetInsideWebArea() {
        let target = element(
            2,
            role: "AXTextField",
            path: [group0, web0, LocatorStep(role: "AXTextField", indexOfRole: 0)])
        #expect(targetIsInWebArea(nil, snapshotElement: target))
    }

    @Test func nonWebSnapshotAncestryDoesNotReportWebArea() {
        let target = element(2, role: "AXTextField", path: [group0, LocatorStep(role: "AXTextField", indexOfRole: 0)])
        #expect(!targetIsInWebArea(nil, snapshotElement: target))
    }
}

@Suite struct WebRendererDetectionTests {
    @Test func cefFrameworkIndicatesWebRenderer() {
        #expect(frameworksIndicateWebRenderer(["Chromium Embedded Framework.framework", "Spotify Helper.app"]))
    }

    @Test func electronFrameworkIndicatesWebRenderer() {
        #expect(frameworksIndicateWebRenderer(["Electron Framework.framework", "Squirrel.framework"]))
    }

    @Test func webKitFrameworkIndicatesWebRenderer() {
        #expect(frameworksIndicateWebRenderer(["WebKit.framework"]))
    }

    @Test func nativeFrameworksDoNot() {
        #expect(!frameworksIndicateWebRenderer(["Sparkle.framework", "SwiftProtobuf.framework"]))
        #expect(!frameworksIndicateWebRenderer([]))
    }
}

@Suite struct SparseTreeHintTests {
    @Test func unsupportedWebAXGetsDirectOCRGuidance() {
        let hint = sparseTreeHint(webAXUnsupported: true)
        #expect(hint.contains("rejects the accessibility opt-in"))
        #expect(hint.contains("ocr:true"))
        #expect(hint.contains("background"))
    }

    @Test func defaultHintSuggestsOCR() {
        let hint = sparseTreeHint(webAXUnsupported: false)
        #expect(hint.contains("ocr:true"))
        #expect(!hint.contains("rejects"))
    }
}
