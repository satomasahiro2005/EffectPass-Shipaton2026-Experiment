//  DeviceDemoUITests.swift
//  Real-device take for the EffectPass demo video (iPad), driven without a human.
//
//  **Not part of normal runs.** Both tests skip themselves unless their switch is in the test
//  runner's environment (pass it to xcodebuild with the TEST_RUNNER_ prefix):
//    ET_DEVICE_DEMO=1   testDeviceDemo: the whole take, screen recording included
//    ET_DEVICE_PROBE=1  testControlCenterProbe: opens Control Center, prints what it finds,
//                       opens the output list and closes it again; records nothing, picks nothing
//  Optional: ET_MUSIC_URL (page with a "Play music" button, or any audio URL),
//            ET_PRO_FLOW=0 (skip the paywall / Bit Crusher part),
//            ET_ORIENTATION=keep|landscape (default landscape),
//            ET_RECORD_SECONDS (EffectPass -ETRecordOutput, default 180).
//
//  The take (EffectPass is launched first, the way a user sets it up):
//    1. EffectPass launches with -ETSeed pv-open (Lo Pass Filter at 300 Hz → Spectrum Analyzer →
//       Level Meter), -ETLayout wide, -ETRecordOutput, and -ETAddDefaults so Bit Crusher is added
//       at 24-bit
//    2. Safari opens the music page; Control Center → Screen Recording; countdown
//    3. play in Safari, a few seconds of the untouched track
//    4. Control Center → output (AirPlay) button → "EffectPass"; close Control Center
//    5. EffectPass in front: the muffled track with the analyzer moving, then the Lo Pass Filter
//       Frequency slider is dragged slowly to its maximum (the reveal), hold
//    6. picker → Lo-Fi (locks) → Bit Crusher → paywall → Monthly → Continue → Test Store
//       "valid purchase" → add Bit Crusher (Bit Depth stays 24) → ZOH Frequency down and back
//    7. Control Center → Screen Recording again (stop)
//
//  Every step prints "DEVDEMO t=<systemUptime> unix=<epoch> <step>". systemUptime is the same
//  clock as the host time in EffectPass's et-output.json, so the recorded audio can be lined up.
//  A step that cannot find its element prints what is on screen ("DEVDEMO PROBLEM") and the run
//  goes on; the problems are listed in one XCTFail at the end.

import XCTest

final class DeviceDemoUITests: XCTestCase {

    private let env = ProcessInfo.processInfo.environment
    private var app: XCUIApplication!
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var problems: [String] = []

    private var musicURL: String {
        env["ET_MUSIC_URL"] ?? "http://192.168.1.138:8765/play.html?src=boogie-down.mp3&t=56"
    }

    override func setUpWithError() throws {
        let demo = env["ET_DEVICE_DEMO"] == "1"
        let probe = env["ET_DEVICE_PROBE"] == "1"
        try XCTSkipUnless(demo || probe,
                          "device demo runs only with TEST_RUNNER_ET_DEVICE_DEMO=1 or TEST_RUNNER_ET_DEVICE_PROBE=1")
        continueAfterFailure = true
    }

    // MARK: - Log helpers

    private func mark(_ step: String) {
        print(String(format: "DEVDEMO t=%.3f unix=%.3f %@",
                     ProcessInfo.processInfo.systemUptime, Date().timeIntervalSince1970, step))
    }

    private func pause(_ seconds: Double, _ note: String) {
        mark("pause \(seconds)s \(note)")
        Thread.sleep(forTimeInterval: seconds)
    }

    private func problem(_ text: String) {
        print("DEVDEMO PROBLEM \(text)")
        problems.append(text)
    }

    /// Print labels and identifiers of everything `root` holds, so a label mismatch can be fixed
    /// from the log. Control Center lives in SpringBoard.
    private func dump(_ why: String, _ root: XCUIApplication) {
        print("DEVDEMO dump \(why) (\(root.description))")
        // One snapshot (one round trip to the device) instead of a query per element.
        if let snap = try? root.snapshot() {
            var lines: [String] = []
            func walk(_ s: XCUIElementSnapshot, _ depth: Int) {
                if lines.count >= 400 { return }
                if !s.label.isEmpty || !s.identifier.isEmpty {
                    let f = s.frame
                    lines.append(String(format: "DEVDEMO   %@type=%lu label=%@ id=%@ value=%@ frame=(%.0f,%.0f,%.0f,%.0f)",
                                        String(repeating: " ", count: min(depth, 20)),
                                        s.elementType.rawValue, s.label, s.identifier,
                                        String(describing: s.value ?? ""), f.minX, f.minY, f.width, f.height))
                }
                for c in s.children { walk(c, depth + 1) }
            }
            walk(snap, 0)
            print(lines.joined(separator: "\n"))
        } else {
            print("DEVDEMO dump: no snapshot")
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "dump-\(why)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitFor(_ timeout: TimeInterval, _ find: () -> XCUIElement?) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let e = find() { return e }
            Thread.sleep(forTimeInterval: 0.3)
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

    private func firstHittable(_ query: XCUIElementQuery,
                               accept: (String) -> Bool = { _ in true }) -> XCUIElement? {
        for e in query.allElementsBoundByIndex where e.exists && e.isHittable && accept(e.label) {
            return e
        }
        return nil
    }

    /// The first hittable element of any type in `root` that matches `predicate`.
    private func anyHittable(_ root: XCUIApplication, _ predicate: NSPredicate) -> XCUIElement? {
        for q in [root.buttons, root.switches, root.cells, root.otherElements, root.staticTexts] {
            if let e = firstHittable(q.matching(predicate)) { return e }
        }
        return nil
    }

    // MARK: - Control Center

    private static let screenRecordingPredicate = NSPredicate(
        format: "label CONTAINS '画面収録' OR label CONTAINS[c] 'Screen Recording' "
              + "OR identifier CONTAINS[c] 'screen-recording' OR identifier CONTAINS[c] 'screenrecording'")

    // The Now Playing module's output button. Not the Wi-Fi/Bluetooth tiles, not Screen Mirroring.
    private static let routeButtonPredicate = NSPredicate(
        format: "(label CONTAINS[c] 'AirPlay' OR label CONTAINS '出力先' OR label CONTAINS 'オーディオ出力' "
              + "OR label CONTAINS[c] 'audio output' OR identifier CONTAINS[c] 'airplay' "
              + "OR identifier CONTAINS[c] 'route') "
              + "AND NOT label CONTAINS 'ミラーリング' AND NOT label CONTAINS[c] 'Mirroring'")

    private static let nowPlayingPredicate = NSPredicate(
        format: "label CONTAINS[c] 'Boogie' OR label CONTAINS[c] 'Vibe Check' OR label CONTAINS '再生中' "
              + "OR label CONTAINS[c] 'Now Playing' OR identifier CONTAINS[c] 'nowplaying' "
              + "OR identifier CONTAINS[c] 'media'")

    private static let effectPassPredicate = NSPredicate(format: "label CONTAINS 'EffectPass'")

    private func screenRecordingButton() -> XCUIElement? {
        anyHittable(springboard, Self.screenRecordingPredicate)
    }

    /// Anything that says Control Center is on screen.
    private var controlCenterOpen: Bool {
        screenRecordingButton() != nil || anyHittable(springboard, Self.routeButtonPredicate) != nil
            || springboard.otherElements.matching(NSPredicate(
                format: "identifier CONTAINS[c] 'ControlCenter' OR label == 'コントロールセンター' "
                      + "OR label == 'Control Center'")).firstMatch.exists
    }

    /// Swipe down from the top-right corner (iPad). The front app's frame follows the orientation.
    @discardableResult
    private func openControlCenter(_ front: XCUIApplication) -> Bool {
        for attempt in 0..<3 {
            let root = front.exists && front.state == .runningForeground ? front : springboard
            let from = root.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.002))
            let to = root.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.55))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0.05)
            if waitUntil(3, { self.controlCenterOpen }) {
                mark("control center open (attempt \(attempt))")
                return true
            }
        }
        problem("Control Center did not open")
        dump("no-control-center", springboard)
        return false
    }

    /// Tap an empty spot (left side, low), then swipe up there if it is still open.
    private func closeControlCenter(_ front: XCUIApplication) {
        for attempt in 0..<3 {
            guard controlCenterOpen else {
                mark("control center closed (attempt \(attempt))")
                return
            }
            let root = front.exists ? front : springboard
            if attempt == 0 {
                root.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.88)).tap()
            } else {
                root.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.75))
                    .press(forDuration: 0.05,
                           thenDragTo: root.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.15)),
                           withVelocity: .fast, thenHoldForDuration: 0.05)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        if controlCenterOpen {
            problem("Control Center did not close")
            dump("control-center-stuck", springboard)
        }
    }

    private func toggleScreenRecording(_ front: XCUIApplication, _ what: String) -> Bool {
        guard openControlCenter(front) else { return false }
        guard let button = waitFor(3, { self.screenRecordingButton() }) else {
            problem("Screen Recording control not in Control Center (\(what))")
            dump("no-screen-recording", springboard)
            closeControlCenter(front)
            return false
        }
        mark("tap screen recording (\(what)) label=\(button.label) value=\(String(describing: button.value))")
        button.tap()
        Thread.sleep(forTimeInterval: 0.8)
        closeControlCenter(front)
        return true
    }

    /// Output button → "EffectPass". `pick` false only lists the routes (probe).
    private func chooseEffectPassOutput(_ front: XCUIApplication, pick: Bool) -> Bool {
        guard openControlCenter(front) else { return false }
        var route = waitFor(2, { self.anyHittable(self.springboard, Self.routeButtonPredicate) })
        if route == nil, let module = anyHittable(springboard, Self.nowPlayingPredicate) {
            // A small Now Playing module may not show its output button; open the module.
            mark("open now playing module label=\(module.label)")
            module.tap()
            route = waitFor(3, { self.anyHittable(self.springboard, Self.routeButtonPredicate) })
        }
        guard let route else {
            problem("output (AirPlay) button not found in Control Center")
            dump("no-route-button", springboard)
            closeControlCenter(front)
            return false
        }
        mark("tap output button label=\(route.label) id=\(route.identifier)")
        route.tap()
        let target = waitFor(6, { self.anyHittable(self.springboard, Self.effectPassPredicate) })
        if !pick { dump("probe-route-list", springboard) }
        guard let target else {
            problem("EffectPass not listed as an output")
            if pick { dump("route-list", springboard) }
            closeControlCenter(front)
            closeControlCenter(front)
            return false
        }
        if pick {
            mark("tap output EffectPass label=\(target.label)")
            target.tap()
            Thread.sleep(forTimeInterval: 2.0)
            if let check = anyHittable(springboard, Self.effectPassPredicate) {
                mark("after pick: \(check.label) value=\(String(describing: check.value)) selected=\(check.isSelected)")
            }
        } else {
            mark("probe: EffectPass listed label=\(target.label)")
        }
        // The route list sits on top of Control Center: one close for each.
        closeControlCenter(front)
        if controlCenterOpen { closeControlCenter(front) }
        return true
    }

    // MARK: - Safari

    private func openMusicPage() -> Bool {
        guard let url = URL(string: musicURL) else {
            problem("bad ET_MUSIC_URL \(musicURL)")
            return false
        }
        XCUIDevice.shared.system.open(url)
        guard safari.wait(for: .runningForeground, timeout: 15) else {
            problem("Safari did not come to the front")
            dump("no-safari", springboard)
            return false
        }
        mark("safari open \(musicURL)")
        return true
    }

    private func playButton(_ label: String = "Play music") -> XCUIElement? {
        let p = NSPredicate(format: "label == %@", label)
        for q in [safari.webViews.buttons, safari.buttons] {
            if let e = firstHittable(q.matching(p)) { return e }
        }
        return nil
    }

    // MARK: - EffectPass

    private var pickerOpen: Bool { app.navigationBars["Available Effects"].exists }

    private func openPicker() -> Bool {
        if pickerOpen { return true }
        let add = app.navigationBars.buttons["Add Effect"]
        guard add.waitForExistence(timeout: 20) else {
            problem("Add Effect button not found")
            dump("no-add-effect", app)
            return false
        }
        add.tap()
        guard app.navigationBars["Available Effects"].waitForExistence(timeout: 15) else {
            problem("effect picker did not open")
            dump("no-picker", app)
            return false
        }
        return true
    }

    private func bitCrusherRow() -> XCUIElement? {
        let chip = app.buttons["Lo-Fi"].firstMatch
        if chip.waitForExistence(timeout: 10) {
            chip.tap()
            pause(1.5, "after Lo-Fi chip")
        } else {
            problem("Lo-Fi chip not found")
            dump("no-lofi-chip", app)
        }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Bit Crusher")).firstMatch
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
        dump("no-bitcrusher", app)
        return nil
    }

    private func lockCount() -> Int {
        let images = app.images.matching(NSPredicate(format: "label == %@", "EffectPass Pro")).count
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", EffectPass Pro")).count
        return max(images, rows)
    }

    private static let ctaPredicate = NSPredicate(
        format: "label CONTAINS[c] 'Continue' OR label CONTAINS[c] 'Subscribe' "
              + "OR label CONTAINS[c] 'Purchase' OR label CONTAINS[c] 'Start'")

    private func paywallCTA() -> XCUIElement? {
        firstHittable(app.buttons.matching(Self.ctaPredicate)) { label in
            !label.contains(", ") && !label.lowercased().contains("restore")
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

    /// A parameter's slider. Sliders carry no label; the value field above it does
    /// ("Frequency (Hz)"), so take the nearest slider below that field in the same column.
    private func slider(below fieldPrefix: String) -> (field: XCUIElement, slider: XCUIElement)? {
        let fields = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", fieldPrefix))
        guard let field = fields.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
                ?? fields.allElementsBoundByIndex.first(where: { $0.exists }) else { return nil }
        let f = field.frame
        let candidates = app.sliders.allElementsBoundByIndex.filter { s in
            guard s.exists else { return false }
            let r = s.frame
            return r.minY >= f.minY && r.minY - f.maxY < 80 && r.maxX > f.minX - 600 && r.minX < f.maxX
        }
        guard let best = candidates.min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
        return (field, best)
    }

    /// Thumb centre for a 0...1 position. The thumb never leaves the track, so the usable span is
    /// the width minus one thumb (about 38 pt for the iOS 26 capsule thumb).
    private func thumb(_ s: XCUIElement, at position: Double) -> XCUICoordinate {
        let r = s.frame
        let inset = min(19.0, r.width / 4)
        let x = inset + max(0, min(1, position)) * (r.width - 2 * inset)
        return s.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: r.height / 2))
    }

    /// Press the thumb at `from`, drag to `to` over about `seconds`, hold.
    private func sweep(_ s: XCUIElement, from: Double, to: Double, seconds: Double,
                       overshoot: Double = 0, hold: Double = 0.3) {
        let r = s.frame
        let start = thumb(s, at: from)
        let end = thumb(s, at: to).withOffset(CGVector(dx: overshoot, dy: 0))
        let distance = abs(to - from) * (r.width - 38) + abs(overshoot)
        let velocity = XCUIGestureVelocity(rawValue: CGFloat(max(20, distance / seconds)))
        start.press(forDuration: 0.25, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: hold)
    }

    private func valueText(_ e: XCUIElement) -> String {
        (e.value as? String) ?? String(describing: e.value)
    }

    // MARK: - The take

    func testDeviceDemo() throws {
        try XCTSkipUnless(env["ET_DEVICE_DEMO"] == "1")
        mark("start")
        if env["ET_ORIENTATION"] != "keep" {
            XCUIDevice.shared.orientation = .landscapeLeft
            mark("orientation landscapeLeft")
        }

        // 1. EffectPass first, the way a user sets it up (the extension hands audio to the app).
        app = XCUIApplication()
        app.launchArguments = ["-ETSeed", "pv-open", "-ETLayout", "wide",
                               "-ETRecordOutput", env["ET_RECORD_SECONDS"] ?? "180",
                               "-ETAddDefaults", #"{"BitCrusherPlugin":{"bd":24}}"#]
        app.launch()
        if app.textFields.matching(NSPredicate(format: "label BEGINSWITH 'Frequency'")).firstMatch
            .waitForExistence(timeout: 20) {
            mark("effectpass launched, Lo Pass Filter visible")
        } else {
            problem("Lo Pass Filter Frequency field not visible after launch")
            dump("no-lpf", app)
        }
        pause(2, "effectpass settles")

        // 2. Safari with the music page, then start the screen recording.
        guard openMusicPage() else { return finish() }
        guard let play = waitFor(20, { self.playButton() }) else {
            problem("Play button not found on the music page")
            dump("no-play", safari)
            return finish()
        }
        pause(1.5, "page loaded")
        let recording = toggleScreenRecording(safari, "start")
        pause(recording ? 4.5 : 1, "screen recording countdown")
        mark("recording should be running: \(recording)")

        // 3. Play: a few seconds of the untouched track.
        mark("tap play")
        play.tap()
        pause(Double(env["ET_CLEAN_SECONDS"] ?? "") ?? 3.5, "clean track in Safari")

        // 4. Output → EffectPass.
        let routed = chooseEffectPassOutput(safari, pick: true)
        mark("routed to EffectPass: \(routed)")
        pause(1, "after routing")

        // 5. EffectPass in front: muffled, then the reveal.
        app.activate()
        mark("effectpass active")
        pause(2, "muffled with analyzer")
        if let lpf = slider(below: "Frequency") {
            mark("lpf before field=\(valueText(lpf.field)) slider=\(valueText(lpf.slider)) frame=\(lpf.slider.frame)")
            // fr 300 on 10...40000 (log): position (log10 300 - 1) / (log10 40000 - 1) = 0.41.
            let startPos = (log10(300.0) - 1) / (log10(40000.0) - 1)
            mark("lpf sweep begin")
            sweep(lpf.slider, from: startPos, to: 1, seconds: 2.2, overshoot: 40, hold: 0.5)
            mark("lpf sweep end field=\(valueText(lpf.field))")
            let after = valueText(lpf.field)
            if !(after.contains("40") || after.contains("k")) {
                problem("Lo Pass Filter did not reach the top (field=\(after)); setting it directly")
                lpf.slider.adjust(toNormalizedSliderPosition: 1)
                mark("lpf adjusted field=\(valueText(lpf.field))")
            }
        } else {
            problem("Lo Pass Filter slider not found")
            dump("no-lpf-slider", app)
        }
        pause(3.5, "open track, analyzer full")

        // 6. Pro: Lo-Fi locks, paywall, Test Store, Bit Crusher.
        if env["ET_PRO_FLOW"] != "0" {
            proFlow()
        }

        // 7. Stop the screen recording.
        pause(1.5, "before stop")
        _ = toggleScreenRecording(app, "stop")
        mark("end")
        finish()
    }

    private func proFlow() {
        guard openPicker() else { return }
        pause(1.5, "picker open")
        guard let row = bitCrusherRow() else { return }
        let locks = lockCount()
        mark("lock icons visible: \(locks)")
        pause(2.5, "show locks")
        let unlocked = locks == 0
        if unlocked { problem("no locks: Pro already active or no RevenueCat key") }
        row.tap()
        if !unlocked {
            guard let cta = waitFor(45, { self.paywallCTA() }) else {
                problem("paywall CTA not found")
                dump("no-paywall-cta", app)
                return
            }
            pause(2.5, "paywall shown")
            if let monthly = firstHittable(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'month'")),
                                           accept: { !$0.lowercased().contains("restore") }) {
                mark("select package \(monthly.label)")
                monthly.tap()
                pause(1.2, "monthly selected")
            }
            let button = paywallCTA() ?? cta
            mark("tap CTA \(button.label)")
            button.tap()
            if let confirm = waitFor(30, { self.testStoreConfirm() }) {
                pause(1.2, "test store sheet")
                mark("tap confirm \(confirm.label)")
                confirm.tap()
            } else {
                problem("Test Store confirmation not found")
                dump("no-test-store-confirm", app)
            }
            if !waitUntil(45, { self.paywallCTA() == nil }) {
                problem("paywall did not dismiss")
                dump("paywall-still-open", app)
            }
            pause(2, "paywall dismissed")
            if !waitUntil(30, { self.paywallCTA() == nil }) { problem("paywall came back") }
            mark("lock icons after purchase: \(lockCount())")
            if !pickerOpen {
                guard openPicker() else { return }
                pause(1.2, "picker reopened")
            }
            guard let row2 = bitCrusherRow() else { return }
            if lockCount() != 0 { problem("locks still visible after purchase: \(lockCount())") }
            pause(1.5, "unlocked list")
            row2.tap()
        }
        mark("bit crusher added")
        pause(2.5, "bit crusher card")

        guard var zoh = slider(below: "ZOH Frequency") else {
            problem("ZOH Frequency slider not found")
            dump("no-zoh", app)
            return
        }
        if !zoh.slider.isHittable {
            // The right column holds the cards; scroll it, not the list on the left.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.35)),
                       withVelocity: .default, thenHoldForDuration: 0.2)
            pause(1, "scroll to ZOH")
            if let again = slider(below: "ZOH Frequency") { zoh = again }
        }
        let depth = app.textFields.matching(NSPredicate(format: "label BEGINSWITH 'Bit Depth'")).firstMatch
        if depth.exists {
            let v = valueText(depth)
            mark("bit depth field=\(v)")
            if !v.contains("24") { problem("Bit Depth is not 24 (\(v))") }
        } else {
            mark("bit depth field not found")
        }
        // zf 44100 on 4000...96000 (linear): position 0.436. Down to ~6.8 kHz and back.
        let home = (44100.0 - 4000) / (96000 - 4000)
        let low = 0.03
        mark("zoh before field=\(valueText(zoh.field))")
        sweep(zoh.slider, from: home, to: low, seconds: 1.8, hold: 1.2)
        mark("zoh down field=\(valueText(zoh.field))")
        sweep(zoh.slider, from: low, to: home, seconds: 1.8, hold: 0.3)
        mark("zoh back field=\(valueText(zoh.field))")
        pause(2.5, "bit crusher back to clean")
    }

    // MARK: - Probe

    /// Opens Control Center over Safari, prints what is there (Screen Recording control, output
    /// button, the output list with EffectPass) and closes it. Starts no recording, picks no output.
    func testControlCenterProbe() throws {
        try XCTSkipUnless(env["ET_DEVICE_PROBE"] == "1")
        mark("probe start")
        if env["ET_ORIENTATION"] != "keep" { XCUIDevice.shared.orientation = .landscapeLeft }
        guard openMusicPage() else { return finish() }
        if let play = waitFor(20, { self.playButton() }) {
            mark("probe: play button label=\(play.label)")
            play.tap()   // a Now Playing session, as in the take
            pause(2, "probe playing")
        } else {
            problem("Play button not found on the music page")
            dump("probe-no-play", safari)
        }
        guard openControlCenter(safari) else { return finish() }
        dump("probe-control-center", springboard)
        if let rec = screenRecordingButton() {
            mark("probe: screen recording label=\(rec.label) id=\(rec.identifier)")
        } else {
            problem("Screen Recording control not found")
        }
        closeControlCenter(safari)
        _ = chooseEffectPassOutput(safari, pick: false)
        if let pauseButton = playButton("Pause music") { pauseButton.tap() }
        mark("probe end")
        finish()
    }

    private func finish() {
        if !problems.isEmpty {
            XCTFail("device demo problems: " + problems.joined(separator: " | "))
        }
    }
}
