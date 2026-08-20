import Testing
@testable import SwiftTerm

// [nova] Regression coverage for NovaScale's iOS wheel bridge and the tmux
// copy-mode output patterns that originally exposed missing row invalidation.
struct TmuxCopyModeRenderingTests {
    private let esc = "\u{1b}"

    /// tmux 3.2a frequently clears old copy-mode position markers with ECH.
    /// The cells changing is insufficient: the view only redraws rows present
    /// in Terminal's update range.
    @Test func eraseCharactersMarksTheRowForDisplay() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 94, rows: 30)
        terminal.feed(text: "\(esc)[6;80H[140/159]")
        terminal.clearUpdateRange()

        terminal.feed(text: "\(esc)[6;80H\(esc)[9X")

        let updateRange = terminal.getUpdateRange()
        #expect(updateRange?.startY == 5)
        #expect(updateRange?.endY == 5)
    }

    /// tmux 3.2a commonly repaints most of the copy-mode viewport after one
    /// wheel report. Recreate a stale-marker screen first, then feed the real
    /// row-update shape (text, ECH, CUF, spaces) and verify that the parser
    /// converges to one marker even when the input begins in that bad state.
    @Test func tmux32aFullVisibleRepaintClearsMarkerTrail() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 94, rows: 30)
        terminal.feed(text: "\(esc)[?1049h")

        for row in 1...20 {
            terminal.feed(text: "\(esc)[\(row);85H\(esc)[30m\(esc)[43m[\(100 - row)/147]")
        }

        for row in 1...29 {
            let content = String(86 + row)
            let skip = 21
            let remaining = 94 - content.count - skip
            terminal.feed(text:
                "\(esc)[\(row);1H\(esc)[39m\(esc)[49m\(content)" +
                "\(esc)[\(skip)X\(esc)[\(skip)C" +
                String(repeating: " ", count: remaining))
        }
        terminal.feed(text: "\(esc)[1;85H\(esc)[30m\(esc)[43m[105/147]")

        let markerRows = TerminalTestHarness.visibleLinesText(
            buffer: terminal.buffer,
            terminal: terminal
        ).filter { $0.contains("/147]") }
        #expect(markerRows.count == 1)
        #expect(markerRows[0].contains("[105/147]"))
    }

    /// tmux 3.5 scrolls copy mode one row by inserting a line, repainting the
    /// new top row, then using LF at the old marker column to erase the marker
    /// that moved to row two. Keep this real output shape as a regression case:
    /// only the newest position marker may remain in the terminal buffer.
    @Test func incrementalCopyModeScrollClearsPreviousPositionMarker() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 94, rows: 30)
        terminal.feed(text: "\(esc)[?1049h\(esc)[1;29r")
        terminal.feed(text: "\(esc)[1;77H\(esc)[30m\(esc)[43m12:51:00 [115/119]\(esc)[m")

        for position in 116...119 {
            let content = String(120 - position)
            terminal.feed(text:
                "\(esc)[1;1H\(esc)[1L" +
                "\(esc)[1;77H\(esc)[30m\(esc)[43m12:51:00 [\(position)/119]" +
                "\(esc)[1;1H\(esc)[39m\(esc)[49m\(content)\(esc)[22C" +
                String(repeating: " ", count: 53) + "\n" +
                String(repeating: " ", count: 18))

            let markerRows = TerminalTestHarness.visibleLinesText(
                buffer: terminal.buffer,
                terminal: terminal
            ).filter { $0.contains("/119]") }
            #expect(markerRows.count == 1)
            #expect(markerRows[0].contains("[\(position)/119]"))
        }
    }
}
