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

    @Test func lineAndColumnPositionIsParsed() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://reuse-window?path=/tmp/a.txt&line=12&col=4")!
        )

        #expect(request?.targets == [
            OpenTarget(
                fileURL: URL(fileURLWithPath: "/tmp/a.txt").standardizedFileURL,
                selection: TextSelection(
                    start: TextPosition(line: 12, column: 4),
                    end: TextPosition(line: 12, column: 4)
                )
            )
        ])
    }

    @Test func lineRangeSelectionIsParsed() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://new-window?path=/tmp/a.txt&line=3-9")!
        )

        #expect(request?.targets.first?.selection == TextSelection(
            start: TextPosition(line: 3, column: nil),
            end: TextPosition(line: 9, column: nil)
        ))
    }

    @Test func columnRangeAppliesToSelectionEndpoints() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://new-window?path=/tmp/a.txt&line=3-9&col=2-7")!
        )

        #expect(request?.targets.first?.selection == TextSelection(
            start: TextPosition(line: 3, column: 2),
            end: TextPosition(line: 9, column: 7)
        ))
    }

    @Test func positionItemsAttachToThePrecedingPath() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://reuse-window?path=/tmp/a.txt&line=2&path=/tmp/b.txt&line=40-42")!
        )

        #expect(request?.targets.map(\.selection) == [
            TextSelection(start: TextPosition(line: 2), end: TextPosition(line: 2)),
            TextSelection(start: TextPosition(line: 40), end: TextPosition(line: 42)),
        ])
    }

    @Test func invalidPositionsRejectTheRequest() {
        for query in ["line=0", "line=5-3", "line=abc", "col=2"] {
            #expect(
                OpenURLInterpreter.interpret(
                    URL(string: "openedit://new-window?path=/tmp/a.txt&\(query)")!
                ) == nil,
                "expected \(query) to reject the request"
            )
        }
    }

    @Test func perOpenOptionsAreParsed() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://new-window?path=/tmp/a.txt&readonly=1&encoding=UTF-8&eol=crlf&tabsize=4&expand-tabs=1&wrap=0&highlighting=0&language=python&config=/tmp/languages.toml&lsp=0&autodetect=0&lsp-language=python&lsp-server=python=/opt/bin/pylsp&lsp-log=/tmp/lsp.log&watcher=0&watch-debounce=250&log-level=debug&log-file=/tmp/openedit.log&debug=1")!
        )

        let options = request!.options
        #expect(options.readOnly)
        #expect(options.encoding == "UTF-8")
        #expect(options.lineEnding == .crlf)
        #expect(options.tabSize == 4)
        #expect(options.expandTabs)
        #expect(options.wrapsLines == false)
        #expect(options.highlighting == false)
        #expect(options.forcedLanguage == "python")
        #expect(options.configPath == "/tmp/languages.toml")
        #expect(options.lspEnabled == false)
        #expect(options.autodetectServers == false)
        #expect(options.lspLanguage == "python")
        #expect(options.lspServerOverrides == ["python": "/opt/bin/pylsp"])
        #expect(options.lspLogPath == "/tmp/lsp.log")
        #expect(options.watchesFile == false)
        #expect(options.watchDebounceMilliseconds == 250)
        #expect(options.logLevel == "debug")
        #expect(options.logFilePath == "/tmp/openedit.log")
        #expect(options.debug)
    }

    @Test func reopenRequestNeedsNoTargets() {
        let request = OpenURLInterpreter.interpret(
            URL(string: "openedit://reuse-window?action=reopen")!
        )

        #expect(request?.action == .reopen)
        #expect(request?.targets.isEmpty == true)
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
