//  DemoWalkthroughUITests.swift
//  Demo video walkthrough for EffectPass Pro (RevenueCat Shipaton), driven without a human.
//
//  **Not part of normal runs.** The test skips itself unless ET_DEMO=1 is in the test
//  runner's environment. Pass it as `TEST_RUNNER_ET_DEMO=1` to xcodebuild
//  (Scripts/record_demo.sh does this). Nothing else in Tests/UI reads it.
//
//  Flow (with 1.5-4 s pauses so a screen recording is watchable):
//    a) launch with the demo chain and mock audio in the iPad two-column layout (-ETLayout wide:
//       chain list on the left, every card expanded on the right), show the running chain
//    b) open the effect picker (a popover from + in two columns), jump to Lo-Fi (a Pro category), show the lock icons, tap Bit Crusher
//    c) the RevenueCat paywall appears; wait, pick the monthly package if any, tap the CTA
//    d) RevenueCat Test Store asks for a purchase result; tap the "valid/success" option
//    e) paywall closes, locks are gone, add Bit Crusher (the right column scrolls to the new card)
//    f) Settings > About shows the "EffectPass Pro" section as Active
//
//  **Label mismatches do not abort the run.** Every step that cannot find its element prints
//  the visible button labels (and app.debugDescription), records a problem, and moves on.
//  The problems are listed in one XCTFail at the end so the next run can be fixed from the log
//  (grep "DEMO" in the xcodebuild output).
//
//  Without Config/Secrets.xcconfig (no RevenueCat key) the app is fully unlocked: no lock icons,
//  no Pro section. The test says so ("DEMO no locks") and fails at the end; only navigation
//  up to the picker is meaningful in that mode.

import XCTest

final class DemoWalkthroughUITests: XCTestCase {

    private var app: XCUIApplication!
    private var problems: [String] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ET_DEMO"] == "1",
                          "demo walkthrough runs only with TEST_RUNNER_ET_DEMO=1")
        continueAfterFailure = true
    }

    // MARK: - Helpers

    private func pause(_ seconds: Double, _ note: String = "") {
        print("DEMO pause \(seconds)s \(note)")
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Full-resolution screenshot for the submission. Kept in the result bundle, and also written
    /// as PNG to ET_SHOTS (a host directory; the simulator shares the Mac's file system) if set.
    private func shoot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "shot-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["ET_SHOTS"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try shot.pngRepresentation.write(to: url)
                print("DEMO shot \(url.path)")
            } catch {
                print("DEMO shot failed \(name): \(error)")
            }
        }
    }

    private func problem(_ text: String) {
        print("DEMO PROBLEM \(text)")
        problems.append(text)
    }

    /// Print what is on screen so a label mismatch can be fixed from the log.
    private func dump(_ why: String) {
        print("DEMO dump: \(why)")
        let buttons = app.buttons.allElementsBoundByIndex.map { "[\($0.label)|\($0.identifier)]" }
        print("DEMO buttons: \(buttons.joined(separator: " "))")
        let alerts = app.alerts.allElementsBoundByIndex.map { $0.label }
        print("DEMO alerts: \(alerts)")
        print(app.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "dump-\(why)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The lock image sits inside the row's Button label, so accessibility usually folds it into
    /// the button ("Bit Crusher, EffectPass Pro, ..."). Count both shapes.
    private func lockCount() -> Int {
        let images = app.images.matching(NSPredicate(format: "label == %@", "EffectPass Pro")).count
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", EffectPass Pro")).count
        return max(images, rows)
    }

    /// The first element of `query` that is on screen and whose label passes `accept`.
    private func firstHittable(_ query: XCUIElementQuery,
                               accept: (String) -> Bool = { _ in true }) -> XCUIElement? {
        for e in query.allElementsBoundByIndex where e.exists && e.isHittable && accept(e.label) {
            return e
        }
        return nil
    }

    // Paywall call-to-action. Picker rows compose "Name, Category, description" labels
    // (contain ", "), so those are excluded; "Restore Purchases" is not the CTA.
    private static let ctaPredicate = NSPredicate(
        format: "label CONTAINS[c] 'Continue' OR label CONTAINS[c] 'Subscribe' "
              + "OR label CONTAINS[c] 'Purchase' OR label CONTAINS[c] 'Start'")

    private func paywallCTA() -> XCUIElement? {
        firstHittable(app.buttons.matching(Self.ctaPredicate)) { label in
            !label.contains(", ")
                && !label.lowercased().contains("restore")
                && !label.lowercased().contains("cancel")
        }
    }

    private static let confirmPredicate = NSPredicate(
        format: "(label CONTAINS[c] 'valid' OR label CONTAINS[c] 'success') "
              + "AND NOT label CONTAINS[c] 'invalid' AND NOT label CONTAINS[c] 'fail'")

    private func testStoreConfirm() -> XCUIElement? {
        for q in [app.alerts.buttons, app.sheets.buttons, app.buttons] {
            if let e = firstHittable(q.matching(Self.confirmPredicate)) { return e }
        }
        return nil
    }

    /// Poll for an element for up to `timeout` seconds.
    private func waitFor(_ timeout: TimeInterval, _ find: () -> XCUIElement?) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let e = find() { return e }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < end
        return nil
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < end
        return false
    }

    private var pickerOpen: Bool { app.navigationBars["Available Effects"].exists }

    private func openPicker() -> Bool {
        if pickerOpen { return true }
        // The toolbar button (a second "Add Effect" lives in the empty-state row).
        let add = app.navigationBars.buttons["Add Effect"]
        guard add.waitForExistence(timeout: 20) else {
            problem("Add Effect button not found")
            dump("no-add-effect")
            return false
        }
        add.tap()
        guard app.navigationBars["Available Effects"].waitForExistence(timeout: 15) else {
            problem("effect picker did not open")
            dump("no-picker")
            return false
        }
        return true
    }

    /// Jump to Lo-Fi and find the Bit Crusher row (first row starting with "Bit Crusher").
    private func bitCrusherRow() -> XCUIElement? {
        let chip = app.buttons["Lo-Fi"].firstMatch
        if chip.waitForExistence(timeout: 10) {
            chip.tap()
            pause(1.5, "after Lo-Fi chip")
        } else {
            problem("Lo-Fi chip not found")
            dump("no-lofi-chip")
        }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Bit Crusher")).firstMatch
        // In two columns the picker is a popover; swipe inside it, not on the chain behind it.
        let popover = app.popovers.firstMatch
        let scroller: XCUIElement = popover.exists ? popover : app
        var tries = 0
        while tries < 6 && !(row.exists && row.isHittable) {
            scroller.swipeUp()
            pause(0.8, "scroll to Bit Crusher")
            tries += 1
        }
        if row.exists { return row }
        problem("Bit Crusher row not found")
        dump("no-bitcrusher")
        return nil
    }

    // MARK: - The walkthrough

    func testDemoWalkthrough() throws {
        // a) launch and show the running chain
        app = XCUIApplication()
        app.launchArguments = ["-ETMock", "1", "-ETSeed", "demo", "-ETLayout", "wide"]
        app.launch()
        pause(3, "a) running chain")
        shoot("0-chain-two-column")
        pause(2, "a) running chain")

        // b) picker, Pro category, locks
        guard openPicker() else { return finish() }
        pause(2, "b) picker open")
        guard let row = bitCrusherRow() else { return finish() }
        let locks = lockCount()
        print("DEMO lock icons visible: \(locks)")
        shoot("1-picker-locked")
        pause(3, "b) show locks")
        let unlocked = locks == 0
        if unlocked {
            problem("no locks: this build has no RevenueCat key (RC_API_KEY), Pro is open")
        }
        row.tap()

        if !unlocked {
            // c) paywall
            let cta = waitFor(45) { self.paywallCTA() }
            guard let cta else {
                problem("paywall CTA not found (Continue/Subscribe/Purchase/Start)")
                dump("no-paywall-cta")
                return finish()
            }
            pause(2, "c) paywall shown")
            shoot("2-paywall")
            pause(2, "c) paywall shown")
            if let monthly = firstHittable(app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'month'")),
                accept: { !$0.lowercased().contains("restore") }) {
                print("DEMO selecting package: \(monthly.label)")
                monthly.tap()
                pause(1.5, "c) monthly selected")
            }
            let button = paywallCTA() ?? cta
            print("DEMO tapping CTA: \(button.label)")
            button.tap()

            // d) Test Store confirmation
            if let confirm = waitFor(30, { self.testStoreConfirm() }) {
                pause(1, "d) test store confirmation")
                shoot("3-test-store")
                pause(1, "d) test store confirmation")
                print("DEMO tapping confirm: \(confirm.label)")
                confirm.tap()
            } else {
                problem("Test Store confirmation button (valid/success) not found")
                dump("no-test-store-confirm")
            }

            // e) paywall dismisses, locks gone
            if !waitUntil(45, { self.paywallCTA() == nil }) {
                problem("paywall did not dismiss")
                dump("paywall-still-open")
            }
            pause(2.5, "e) paywall dismissed")
            // The CTA can vanish for a moment behind the purchase spinner; check again.
            if !waitUntil(30, { self.paywallCTA() == nil }) { problem("paywall came back") }
            print("DEMO lock icons after purchase: \(lockCount())")
            if pickerOpen == false {
                guard openPicker() else { return finish() }
                pause(1.5, "e) picker reopened")
            }
            guard let row2 = bitCrusherRow() else { return finish() }
            if lockCount() != 0 { problem("locks still visible after purchase: \(lockCount())") }
            shoot("4-unlocked")
            pause(2, "e) unlocked list")
            row2.tap()
        }
        pause(2.5, "e) effect added")
        // Picking closes the popover and the right column scrolls to the new card. Look for the
        // card, not the left list's row: the card holds the effect's controls.
        let added = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Bit Crusher"))
        if !waitUntil(10, { added.count > 0 }) {
            problem("Bit Crusher not visible in the chain after adding")
        }
        print("DEMO Bit Crusher elements after adding: \(added.count), hittable: "
              + "\(added.allElementsBoundByIndex.filter { $0.isHittable }.count)")
        shoot("4b-added")
        pause(3.5, "e) Bit Crusher in the chain")

        // f) Settings > About > EffectPass Pro
        let more = app.buttons["moreMenu"]
        guard more.waitForExistence(timeout: 20) else {
            problem("moreMenu button not found")
            dump("no-moremenu")
            return finish()
        }
        more.tap()
        pause(1.5, "f) menu open")
        app.buttons["Settings"].firstMatch.tap()
        // The sheet's navigation bar has no "Settings" name on iPad (its title is the Audio/About
        // segments), so wait for the About segment instead.
        let about = app.buttons["About"].firstMatch
        guard about.waitForExistence(timeout: 20) else {
            problem("Settings did not open (no About segment)")
            dump("no-settings")
            return finish()
        }
        pause(2, "f) settings open")
        about.tap()
        pause(1.5, "f) about pane")
        if !unlocked {
            // LabeledContent in a Form may be one element (label "EffectPass Pro", value "Active").
            let active = app.descendants(matching: .any).matching(NSPredicate(
                format: "label == 'Active' OR value == 'Active' OR label ENDSWITH ', Active'")).firstMatch
            if !active.waitForExistence(timeout: 10) {
                problem("Settings shows no 'Active' for EffectPass Pro")
                dump("no-active")
            }
        }
        pause(1, "f) settle")
        shoot("5-settings-pro")
        pause(4, "f) EffectPass Pro section")
        finish()
    }

    private func finish() {
        if !problems.isEmpty {
            XCTFail("demo walkthrough problems: " + problems.joined(separator: " | "))
        }
    }
}
