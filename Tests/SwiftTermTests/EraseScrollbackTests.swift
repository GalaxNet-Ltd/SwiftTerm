import Testing
@testable import SwiftTerm

/// [nova] CSI 3 J changes viewport geometry without moving the cursor.
struct EraseScrollbackTests {
    @Test func eraseSavedLinesNotifiesViewportAndInvalidatesDisplay() {
        let sequence = Array("\u{1B}[3J".utf8)
        for split in 0...sequence.count {
            let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5, scrollback: 100)
            for index in 0..<20 {
                terminal.feed(text: "line \(index)\r\n")
            }
            let visibleLines = TerminalTestHarness.visibleLinesText(buffer: terminal.buffer)
            let cursor = terminal.buffer.y
            delegate.scrolledPositions.removeAll()
            terminal.clearUpdateRange()

            terminal.feed(buffer: sequence[..<split])
            terminal.feed(buffer: sequence[split...])

            #expect(terminal.buffer.lines.count == terminal.rows)
            #expect(terminal.buffer.yBase == 0)
            #expect(terminal.buffer.yDisp == 0)
            #expect(terminal.buffer.y == cursor)
            #expect(TerminalTestHarness.visibleLinesText(buffer: terminal.buffer) == visibleLines)
            #expect(delegate.scrolledPositions == [0])
            #expect(terminal.getUpdateRange() != nil)
        }
    }

    @Test func erasingEmptyScrollbackDoesNotEmitSpuriousViewportChanges() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5, scrollback: 100)
        terminal.feed(text: "kept")
        delegate.scrolledPositions.removeAll()
        terminal.feed(text: "\u{1B}[3J")
        #expect(delegate.scrolledPositions.isEmpty)
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "kept")
    }
}
