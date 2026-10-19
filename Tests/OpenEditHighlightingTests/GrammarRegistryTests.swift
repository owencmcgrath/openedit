import AppKit
import Testing

@testable import OpenEditHighlighting

@Suite struct GrammarRegistryTests {
    @Test func allBundledGrammarsResolve() {
        let registry = GrammarRegistry()
        for name in GrammarRegistry.bundledGrammarNames.sorted() {
            if case let .failure(diagnostic) = registry.configuration(forGrammar: name) {
                Issue.record("\(name): \(diagnostic)")
            }
        }
    }

    @Test func unknownGrammarIsDiagnosed() {
        let registry = GrammarRegistry()
        guard case let .failure(diagnostic) = registry.configuration(forGrammar: "cobol") else {
            Issue.record("expected failure")
            return
        }
        #expect(diagnostic == .grammarNotBundled(grammarName: "cobol"))
    }
}
