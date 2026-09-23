import Testing
@testable import SwiftTerm

// [nova] ReleaseGuard: Neovim must discover OSC 52 before it can use clipboard copy.
struct ClipboardCapabilityTests {
    @Test func primaryDeviceAttributesAdvertiseClipboardSupport() {
        for query in ["\u{1b}[c", "\u{1b}[0c"] {
            let delegate = TerminalTestDelegate()
            let terminal = Terminal(delegate: delegate,
                                    options: TerminalOptions(termName: "xterm-256color"))
            terminal.feed(text: query)

            #expect(delegate.sentData.count == 1)
            let response = String(decoding: delegate.sentData.flatMap { $0 }, as: UTF8.self)
            #expect(response.hasPrefix("\u{1b}[?"))
            #expect(response.hasSuffix("c"))
            #expect(response.dropFirst(3).dropLast().split(separator: ";").contains("52"))
        }
    }

    @Test func clipboardCapabilityQuerySurvivesEveryTransportSplit() {
        let prefix = Array("\u{1b}P+q4d73".utf8) // XTGETTCAP Ms
        for terminator: [UInt8] in [[0x1b, 0x5c], [0x9c]] {
            let query = prefix + terminator
            for split in 0...query.count {
                let (terminal, delegate) = TerminalTestHarness.makeTerminal()
                terminal.feed(byteArray: Array(query[..<split]))
                terminal.feed(byteArray: Array(query[split...]))

                #expect(delegate.sentData == [Array("\u{1b}P1+r4d73=1b5d3532\u{1b}\\".utf8)],
                        "Terminator \(terminator), transport split at byte \(split)")
            }
        }
    }

    @Test func unknownCapabilityIsNotAdvertisedAsClipboardSupport() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}P+q5a5a\u{1b}\\") // XTGETTCAP ZZ

        #expect(delegate.sentData == [Array("\u{1b}P0+r5a5a\u{1b}\\".utf8)])
    }
}
