import Foundation
import Testing

@testable import OpenEditWindowing

@Suite struct OpenURLInterpreterTests {

    @Test func newWindowIntentWithSinglePath() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://new-window?path=/tmp/a.txt")!
        )

        #expect(request == OpenRequest(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.txt").standardizedFileURL],
            intent: .newWindow
        ))
    }

    @Test func reuseWindowIntentIsParsed() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://reuse-window?path=/tmp/a.txt")!
        )

        #expect(request?.intent == .reuseExistingWindow)
    }

    @Test func multiplePathsArePreservedInOrder() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://new-window?path=/tmp/a.txt&path=/tmp/b.txt")!
        )

        #expect(request?.fileURLs == [
            URL(fileURLWithPath: "/tmp/a.txt").standardizedFileURL,
            URL(fileURLWithPath: "/tmp/b.txt").standardizedFileURL
        ])
    }

    @Test func percentEncodedPathsAreDecoded() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://new-window?path=/tmp/a%20b.txt")!
        )

        #expect(request?.fileURLs == [URL(fileURLWithPath: "/tmp/a b.txt").standardizedFileURL])
    }

    @Test func schemeIsCaseInsensitive() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "OpenEdit://NEW-WINDOW?path=/tmp/a.txt")!
        )

        #expect(request?.intent == .newWindow)
    }

    @Test func hostIsRequired() {
        #expect(OpenURLInterpreter.interpret(URL(string: "openedit://")!) == nil)
        #expect(OpenURLInterpreter.interpret(URL(string: "openedit://unknown?path=/tmp/a.txt")!) == nil)
    }

    @Test func missingPathIsRejected() {
        #expect(OpenURLInterpreter.interpret(URL(string: "openedit://new-window")!) == nil)
        #expect(OpenURLInterpreter.interpret(URL(string: "openedit://new-window?other=1")!) == nil)
    }

    @Test func nonOpeneditURLsAreNotInterpreted() {
        #expect(OpenURLInterpreter.interpret(URL(fileURLWithPath: "/tmp/a.txt")) == nil)
        #expect(OpenURLInterpreter.interpret(URL(string: "https://example.com/a.txt")!) == nil)
    }
}

@Suite struct OpenPlacementRouterTests {

    @Test func reuseWithExistingWindowTabs() {
        #expect(OpenPlacementRouter.placement(
            intent: .reuseExistingWindow,
            hasReusableWindow: true
        ) == .reuseExistingWindow)
    }

    @Test func reuseWithoutAWindowOpensNew() {
        #expect(OpenPlacementRouter.placement(
            intent: .reuseExistingWindow,
            hasReusableWindow: false
        ) == .newWindow)
    }

    @Test func explicitNewWindowAlwaysOpensNew() {
        #expect(OpenPlacementRouter.placement(
            intent: .newWindow,
            hasReusableWindow: true
        ) == .newWindow)
        #expect(OpenPlacementRouter.placement(
            intent: .newWindow,
            hasReusableWindow: false
        ) == .newWindow)
    }
}
