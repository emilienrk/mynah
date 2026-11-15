// ClipboardServiceTests.swift
// MynahTests

import AppKit
import Testing

@MainActor
struct ClipboardServiceTests {

    /// A throwaway named pasteboard, so tests never touch the user's own clipboard.
    private func makeService() -> (ClipboardService, NSPasteboard) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.mynah.tests.\(UUID().uuidString)"))
        return (ClipboardService(pasteboard: pb, autoPasteEnabled: { true }), pb)
    }

    @Test("Restoring puts the previous text back")
    func restoreBringsBackPreviousText() {
        let (service, pb) = makeService()
        pb.clearContents()
        pb.setString("what the user had copied", forType: .string)

        let snapshot = service.snapshotPasteboard()
        let changeCount = service.copyToClipboard("the transcription")
        #expect(pb.string(forType: .string) == "the transcription")

        service.restorePasteboard(snapshot, ifUnchangedSince: changeCount)

        #expect(pb.string(forType: .string) == "what the user had copied")
    }

    @Test("Snapshot keeps every type of an item")
    func snapshotPreservesAllTypes() {
        let (service, pb) = makeService()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data([0x01, 0x02]), forType: .tiff)
        pb.writeObjects([item])

        let snapshot = service.snapshotPasteboard()
        let changeCount = service.copyToClipboard("the transcription")
        service.restorePasteboard(snapshot, ifUnchangedSince: changeCount)

        #expect(pb.string(forType: .string) == "plain")
        #expect(pb.data(forType: .tiff) == Data([0x01, 0x02]))
    }

    @Test("A write by someone else cancels the restore")
    func concurrentWriteCancelsRestore() {
        let (service, pb) = makeService()
        pb.clearContents()
        pb.setString("old", forType: .string)

        let snapshot = service.snapshotPasteboard()
        let changeCount = service.copyToClipboard("the transcription")

        // The user hits ⌘C on something else during the paste delay.
        pb.clearContents()
        pb.setString("just copied by the user", forType: .string)

        service.restorePasteboard(snapshot, ifUnchangedSince: changeCount)

        #expect(pb.string(forType: .string) == "just copied by the user")
    }

    @Test("An empty pasteboard is restored empty")
    func emptyPasteboardStaysEmpty() {
        let (service, pb) = makeService()
        pb.clearContents()

        let snapshot = service.snapshotPasteboard()
        let changeCount = service.copyToClipboard("the transcription")
        service.restorePasteboard(snapshot, ifUnchangedSince: changeCount)

        #expect(pb.string(forType: .string) == nil)
    }

    /// ⌘V with nothing editable focused only earns the macOS rejection beep.
    @Test("Nothing editable focused: the text is copied, never pasted")
    func notEditableFocusSkipsPaste() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.mynah.tests.\(UUID().uuidString)"))
        let service = ClipboardService(
            pasteboard: pb,
            focusState: { .notEditable },
            autoPasteEnabled: { true },
            notifyCopied: {}
        )

        let result = await service.copyAndPaste("the transcription")

        #expect(result == .copiedOnly(nil))
        #expect(pb.string(forType: .string) == "the transcription")
    }

    // MARK: - Paste decision

    private static let zed = PasteTarget(bundleID: "dev.zed.Zed", name: "Zed")

    /// Never posts a real ⌘V: `pastes` counts the keystrokes it would have sent.
    @MainActor
    private final class Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mynah.tests.\(UUID().uuidString)"))
        var focusStates: [FocusState]
        var focusReads = 0
        var pastes = 0
        var autoPaste = true
        var alwaysPaste: Set<String> = []

        init(focus: [FocusState]) {
            focusStates = focus
            pasteboard.clearContents()
            pasteboard.setString("what the user had copied", forType: .string)
        }

        @MainActor
        func makeService(settleTime: Duration = .milliseconds(200)) -> ClipboardService {
            ClipboardService(
                pasteboard: pasteboard,
                focusState: {
                    // The last state repeats once the scripted ones run out.
                    let state = self.focusStates[min(self.focusReads, self.focusStates.count - 1)]
                    self.focusReads += 1
                    return state
                },
                focusSettleTime: settleTime,
                focusPollInterval: .milliseconds(10),
                frontmostApp: { ClipboardServiceTests.zed },
                autoPasteEnabled: { self.autoPaste },
                alwaysPasteApps: { self.alwaysPaste },
                isTrusted: { true },
                sendPaste: { self.pastes += 1; return true },
                notifyCopied: {}
            )
        }
    }

    @Test("A field in sight: pasted, then the user's clipboard is handed back")
    func editableFocusPastesAndRestores() async {
        let harness = Harness(focus: [.editable])

        let result = await harness.makeService().copyAndPaste("the transcription")

        #expect(result == .pasted)
        #expect(harness.pastes == 1)
        #expect(harness.pasteboard.string(forType: .string) == "what the user had copied")
    }

    @Test("No field, app not listed: copied, and the app is offered for the list")
    func unlistedAppIsOffered() async {
        let harness = Harness(focus: [.notEditable])

        let result = await harness.makeService().copyAndPaste("the transcription")

        #expect(result == .copiedOnly(Self.zed))
        #expect(harness.pastes == 0)
        #expect(harness.pasteboard.string(forType: .string) == "the transcription")
    }

    @Test("No field, app listed: pasted anyway, and the text stays on the pasteboard")
    func listedAppPastesWithoutRestore() async {
        let harness = Harness(focus: [.notEditable])
        harness.alwaysPaste = [Self.zed.bundleID]

        let result = await harness.makeService().copyAndPaste("the transcription")

        #expect(result == .pastedUnverified)
        #expect(harness.pastes == 1)
        #expect(harness.pasteboard.string(forType: .string) == "the transcription")
    }

    @Test("Unknown focus, app listed: pasted, text kept")
    func listedAppWithUnknownFocusPastesWithoutRestore() async {
        let harness = Harness(focus: [.unknown])
        harness.alwaysPaste = [Self.zed.bundleID]

        let result = await harness.makeService(settleTime: .milliseconds(30)).copyAndPaste("the transcription")

        #expect(result == .pastedUnverified)
        #expect(harness.pasteboard.string(forType: .string) == "the transcription")
    }

    @Test("A listed app with a field in sight still gets its clipboard back")
    func listedAppWithFieldRestores() async {
        let harness = Harness(focus: [.editable])
        harness.alwaysPaste = [Self.zed.bundleID]

        let result = await harness.makeService().copyAndPaste("the transcription")

        #expect(result == .pasted)
        #expect(harness.pasteboard.string(forType: .string) == "what the user had copied")
    }

    /// The tree Chromium builds after the wake can show up a moment late.
    @Test("Unknown focus is asked again until a field shows up")
    func unknownFocusIsPolledUntilEditable() async {
        let harness = Harness(focus: [.unknown, .unknown, .editable])

        let result = await harness.makeService().copyAndPaste("the transcription")

        #expect(result == .pasted)
        #expect(harness.focusReads == 3)
    }

    @Test("Unknown focus that never settles ends copied, within the cap")
    func unknownFocusGivesUpAfterCap() async {
        let harness = Harness(focus: [.unknown])
        let started = ContinuousClock.now

        let result = await harness.makeService(settleTime: .milliseconds(100)).copyAndPaste("the transcription")

        #expect(result == .copiedOnly(Self.zed))
        #expect(harness.pastes == 0)
        #expect(harness.focusReads > 1)
        // The cap, plus the copy and some scheduling slack — not an open-ended wait.
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("A field clearly not editable is not asked again")
    func notEditableIsNotPolled() async {
        let harness = Harness(focus: [.notEditable])

        _ = await harness.makeService().copyAndPaste("the transcription")

        #expect(harness.focusReads == 1)
    }

    @Test("Auto-paste off: nothing is offered, nothing is read")
    func autoPasteOffOffersNothing() async {
        let harness = Harness(focus: [.notEditable])
        harness.autoPaste = false
        let service = harness.makeService()

        let result = await service.copyAndPaste("the transcription")

        #expect(result == .copiedOnly(nil))
        #expect(harness.focusReads == 0)
    }

    // MARK: - Focus classification

    private func traits(_ role: String?, settable: Bool = false, editableAncestor: Bool = false) -> AXElementTraits {
        AXElementTraits(role: role, isValueSettable: settable, hasEditableAncestor: editableAncestor)
    }

    @Test("Static text inside a text area counts as the text area")
    func staticTextInsideFieldIsEditable() {
        let state = FocusClassifier.state(
            focused: traits(kAXStaticTextRole),
            ancestors: [traits(kAXGroupRole), traits(kAXTextAreaRole)]
        )
        #expect(state == .editable)
    }

    @Test("Web content inside an editable region is editable")
    func editableAncestorIsEditable() {
        let state = FocusClassifier.state(focused: traits(kAXStaticTextRole, editableAncestor: true), ancestors: [])
        #expect(state == .editable)
    }

    @Test("Static text in a page is not a field, whatever is above the web area")
    func staticTextInPageIsNotEditable() {
        let state = FocusClassifier.state(
            focused: traits(kAXStaticTextRole),
            ancestors: [traits("AXWebArea"), traits(kAXTextAreaRole)]
        )
        #expect(state == .notEditable)
    }

    /// Chromium marks nearly every node value-settable.
    @Test("A value-settable ancestor alone does not make static text a field")
    func settableAncestorIsNotEnough() {
        let state = FocusClassifier.state(
            focused: traits(kAXStaticTextRole),
            ancestors: [traits(kAXGroupRole, settable: true)]
        )
        #expect(state == .notEditable)
    }

    @Test("A button is not walked up from")
    func buttonIsNotEditable() {
        let state = FocusClassifier.state(focused: traits(kAXButtonRole), ancestors: [traits(kAXTextAreaRole)])
        #expect(state == .notEditable)
    }

    @Test("An unreadable role is unknown")
    func unreadableRoleIsUnknown() {
        #expect(FocusClassifier.state(focused: traits(nil), ancestors: []) == .unknown)
    }

    @Test("The parent walk is bounded")
    func ancestorWalkIsBounded() {
        let deep = Array(repeating: traits(kAXGroupRole), count: FocusClassifier.maxAncestors) + [traits(kAXTextAreaRole)]
        #expect(FocusClassifier.state(focused: traits(kAXStaticTextRole), ancestors: deep) == .notEditable)
    }
}
