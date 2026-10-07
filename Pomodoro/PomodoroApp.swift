import SwiftUI
import Combine
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - Timer Mode
enum TimerMode: String, CaseIterable, Codable {
    case work
    case shortBreak
    case longBreak

    // Display name (in the selected language)
    var displayName: String {
        switch self {
        case .work: return L("mode.work")
        case .shortBreak: return L("mode.shortBreak")
        case .longBreak: return L("mode.longBreak")
        }
    }

    var color: Color {
        switch self {
        case .work: return .red
        case .shortBreak: return .green
        case .longBreak: return .blue
        }
    }

    var nsColor: NSColor {
        switch self {
        case .work: return .systemRed
        case .shortBreak: return .systemGreen
        case .longBreak: return .systemBlue
        }
    }
}

// Stored value of the "Silent" option. The UI shows L("sound.silent").
let silentSoundID = "Silent"
let systemSounds = [silentSoundID, "Glass", "Ping", "Hero", "Submarine", "Basso", "Frog", "Funk", "Morse", "Pop", "Purr", "Sosumi", "Tink"]

// MARK: - Language / Localization
// The app follows the Mac's language by default; it can also be chosen in Settings.
// Strings are read from Localizable.strings in en.lproj / tr.lproj through the bundle
// of the selected language, so a language change applies instantly without a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    // Declaration order = segment order in Settings: System | Türkçe | English
    case system
    case turkish = "tr"
    case english = "en"

    var id: String { rawValue }

    // Language names are always shown in their own language; only "System" is translated.
    var pickerLabel: String {
        switch self {
        case .system: return L("language.system")
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }
}

final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    static let supportedCodes = ["en", "tr"]
    private static let preferenceKey = "appLanguage"

    @Published private(set) var preference: AppLanguage
    @Published private(set) var code: String
    private(set) var bundle: Bundle

    var locale: Locale {
        Locale(identifier: code == "tr" ? "tr_TR" : "en_US")
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.preferenceKey) ?? ""
        let pref = AppLanguage(rawValue: stored) ?? .system
        let resolved = Self.resolveCode(for: pref)
        preference = pref
        code = resolved
        bundle = Self.bundle(for: resolved)
    }

    func setPreference(_ newValue: AppLanguage) {
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.preferenceKey)
        let resolved = Self.resolveCode(for: newValue)
        bundle = Self.bundle(for: resolved)   // make the bundle ready before publishing
        preference = newValue
        code = resolved
    }

    // "System": the language macOS picks for this app from the Mac's preferred languages
    // (and the per-app language in System Settings). Falls back to English if unsupported.
    private static func resolveCode(for preference: AppLanguage) -> String {
        switch preference {
        case .english: return "en"
        case .turkish: return "tr"
        case .system:
            let preferred = Bundle.main.preferredLocalizations.first ?? "en"
            return supportedCodes.contains(preferred) ? preferred : "en"
        }
    }

    private static func bundle(for code: String) -> Bundle {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else { return Bundle.main }
        return b
    }
}

// Localized string
func L(_ key: String) -> String {
    LanguageManager.shared.bundle.localizedString(forKey: key, value: nil, table: nil)
}

// Localized format string (e.g. "%d")
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: LanguageManager.shared.locale, arguments: args)
}

// Singular/plural: uses "<key>.one" when count == 1, otherwise "<key>.other".
func LP(_ key: String, count: Int, _ args: CVarArg...) -> String {
    let fullKey = key + (count == 1 ? ".one" : ".other")
    return String(format: L(fullKey), locale: LanguageManager.shared.locale, arguments: args)
}

// MARK: - Developer info
enum AppInfo {
    static let developerName = "Mustafa Çiçek"
    static let githubURL = URL(string: "https://github.com/mustafacicek-eee")!
    static let linkedinURL = URL(string: "https://www.linkedin.com/in/mustafacicek-eee/")!
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static let copyrightLine = "© 2026 Mustafa Çiçek · MIT License"
}

// MARK: - NSApplication helper
// FIX: activate(ignoringOtherApps:) is deprecated in macOS 14. Use the new API when available.
extension NSApplication {
    func activateAndFocus() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Single Instance Check
// FIX (double launch): If a copy with the same bundle ID was started earlier, the new copy
// quits without creating any window / menu bar icon and tells the old copy to "show your window".
// The check runs in App.init → before the SwiftUI scenes are set up.
// If two copies start at the same moment, launchDate/PID ensures only one survives.
enum SingleInstance {
    static var showWindowNotification: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "PomodoroApp") + ".showMainWindow")
    }

    static func exitIfAnotherInstanceIsRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let myPID = me.processIdentifier
        let myLaunch = me.launchDate ?? Date()

        let olderInstanceExists = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
            // FIX: An old process that is shutting down (e.g. just told to "Quit", or stopped by Xcode)
            // can still appear in the list for a moment. Check that the process is really alive;
            // otherwise the new copy quits for no reason and the app looks like it "won't open".
            .filter { kill($0.processIdentifier, 0) == 0 || errno == EPERM }
            .contains { other in
                let otherLaunch = other.launchDate ?? .distantPast
                return otherLaunch < myLaunch
                    || (otherLaunch == myLaunch && other.processIdentifier < myPID)
            }

        guard olderInstanceExists else { return }
        DistributedNotificationCenter.default().postNotificationName(
            showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
}

// MARK: - Main Window Manager
// FIX (not coming to front): The old code looked up the window with `NSApp.windows.first { !($0 is NSPanel) }`.
// The menu bar icon's own window (NSStatusBarWindow) is NOT an NSPanel,
// so the wrong window could be found. Now the main window is registered directly from
// SwiftUI and every show/hide goes through this single reference.
final class MainWindowManager: NSObject, NSWindowDelegate {
    static let shared = MainWindowManager()

    private weak var window: NSWindow?

    // FIX: SwiftUI sets its own delegate (AppKitWindowController) on the window and runs its
    // internals through it. The old code OVERWROTE that delegate entirely. Now the original
    // delegate is kept and every delegate message we don't implement is forwarded to it
    // (ObjC message forwarding). We only take over windowShouldClose (hide).
    // nonisolated(unsafe): the responds/forwardingTarget overrides inherited from NSObject
    // are nonisolated; this field is only written on the main thread.
    private nonisolated(unsafe) var originalDelegate: NSWindowDelegate?

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = originalDelegate, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }

    // Called by WindowAccessor inside ContentView.
    func register(_ newWindow: NSWindow) {
        let isFirst = (window == nil)
        if window !== newWindow {
            if let old = window {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didBecomeKeyNotification, object: old)
            }
            window = newWindow
            NotificationCenter.default.addObserver(
                self, selector: #selector(mainWindowBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: newWindow)
        }
        configure(newWindow)
        if isFirst {
            // Bring the window to the front at launch (same as the old behavior)
            Task { @MainActor [weak self] in self?.show() }
        }
    }

    private func configure(_ win: NSWindow) {
        if win.delegate !== self {
            // Store the original FIRST, THEN assign ourselves: NSWindow queries which methods are
            // supported via responds(to:) at the moment the delegate is assigned.
            originalDelegate = win.delegate
            win.delegate = self
        }
        win.isMovableByWindowBackground = true
        // If the window is shown while you're on another desktop (Space), bring it to the
        // current desktop instead of jumping back to the old Space.
        var behavior = win.collectionBehavior
        if !behavior.contains(.moveToActiveSpace) {
            behavior.remove(.canJoinAllSpaces) // cannot be combined with moveToActiveSpace
            behavior.insert(.moveToActiveSpace)
            win.collectionBehavior = behavior
        }
    }

    // Reattach if SwiftUI takes the delegate back
    @objc private func mainWindowBecameKey(_ note: Notification) {
        guard let win = note.object as? NSWindow, win === window else { return }
        configure(win)
    }

    // Show the window and bring it to the VERY FRONT.
    // orderFrontRegardless: puts the window above other apps even if the app is not active
    // (accessory app, timer finished, macOS 14+ cooperative activation refusal).
    func show() {
        guard let win = window else { return }
        configure(win)
        if win.isMiniaturized { win.deminiaturize(nil) }
        NSApp.activateAndFocus()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    // Menu bar left click: hide if the window is already in front and focused, otherwise bring it to front.
    // (The old code hid the window even when it was BEHIND other apps.)
    // Note: macOS 14+ does not guarantee the app gets focus (cooperative activation).
    // If focus could not be taken, this brings the window to front again instead of hiding it.
    func toggle() {
        guard let win = window else { return }
        // If an alert/sheet is open in the window, the sheet is key; count that as "focused" too.
        let key = NSApp.keyWindow
        let isFocused = NSApp.isActive && key != nil && (key === win || key?.sheetParent === win)
        if win.isVisible && !win.isMiniaturized && isFocused {
            win.orderOut(nil)
        } else {
            show()
        }
    }

    // Clicking X hides the window instead of quitting the app
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Window Accessor
// Reliably captures the NSWindow that contains the SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onWindow = onWindow
    }
}

final class WindowReportingView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let win = window { onWindow?(win) }
    }

    // Never intercept clicks (buttons and window dragging stay unaffected)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Settings Manager
class SettingsManager {
    static let shared = SettingsManager()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let workDuration = "workDuration"
        static let shortBreakDuration = "shortBreakDuration"
        static let longBreakDuration = "longBreakDuration"
        static let longBreakInterval = "longBreakInterval"
        static let pomodoroCount = "pomodoroCount"
        static let dailyWorkCount = "dailyWorkCount"
        static let dailyShortBreakCount = "dailyShortBreakCount"
        static let dailyLongBreakCount = "dailyLongBreakCount"
        static let lastResetDate = "lastResetDate"
        static let notificationSound = "notificationSound"
        static let autoStart = "autoStart"
        static let extendEnabled = "extendEnabled"
        static let twoMinWarning = "twoMinWarning"
        static let dailyGoalEnabled = "dailyGoalEnabled"
        static let dailyGoalCount = "dailyGoalCount"
        static let tickingEnabled = "tickingEnabled"
        static let notificationVolume = "notificationVolume"
        static let currentStreak = "currentStreak"
        static let lastStreakDate = "lastStreakDate"
        static let dailyStats = "dailyStats"
    }

    var workDuration: Int {
        get { defaults.integer(forKey: Keys.workDuration) == 0 ? 25 : defaults.integer(forKey: Keys.workDuration) }
        set { defaults.set(newValue, forKey: Keys.workDuration) }
    }
    var shortBreakDuration: Int {
        get { defaults.integer(forKey: Keys.shortBreakDuration) == 0 ? 5 : defaults.integer(forKey: Keys.shortBreakDuration) }
        set { defaults.set(newValue, forKey: Keys.shortBreakDuration) }
    }
    var longBreakDuration: Int {
        get { defaults.integer(forKey: Keys.longBreakDuration) == 0 ? 15 : defaults.integer(forKey: Keys.longBreakDuration) }
        set { defaults.set(newValue, forKey: Keys.longBreakDuration) }
    }
    var longBreakInterval: Int {
        get { defaults.integer(forKey: Keys.longBreakInterval) == 0 ? 4 : defaults.integer(forKey: Keys.longBreakInterval) }
        set { defaults.set(newValue, forKey: Keys.longBreakInterval) }
    }
    var pomodoroCount: Int {
        get { defaults.integer(forKey: Keys.pomodoroCount) }
        set { defaults.set(newValue, forKey: Keys.pomodoroCount) }
    }
    var dailyWorkCount: Int {
        get { defaults.integer(forKey: Keys.dailyWorkCount) }
        set { defaults.set(newValue, forKey: Keys.dailyWorkCount) }
    }
    var dailyShortBreakCount: Int {
        get { defaults.integer(forKey: Keys.dailyShortBreakCount) }
        set { defaults.set(newValue, forKey: Keys.dailyShortBreakCount) }
    }
    var dailyLongBreakCount: Int {
        get { defaults.integer(forKey: Keys.dailyLongBreakCount) }
        set { defaults.set(newValue, forKey: Keys.dailyLongBreakCount) }
    }
    var lastResetDate: Date? {
        get { defaults.object(forKey: Keys.lastResetDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastResetDate) }
    }
    var notificationSound: String {
        get { defaults.string(forKey: Keys.notificationSound) ?? "Glass" }
        set { defaults.set(newValue, forKey: Keys.notificationSound) }
    }
    var autoStart: Bool {
        get { defaults.bool(forKey: Keys.autoStart) }
        set { defaults.set(newValue, forKey: Keys.autoStart) }
    }
    var extendEnabled: Bool {
        get { defaults.bool(forKey: Keys.extendEnabled) }
        set { defaults.set(newValue, forKey: Keys.extendEnabled) }
    }
    var twoMinWarning: Bool {
        get { defaults.bool(forKey: Keys.twoMinWarning) }
        set { defaults.set(newValue, forKey: Keys.twoMinWarning) }
    }
    var dailyGoalEnabled: Bool {
        get { defaults.bool(forKey: Keys.dailyGoalEnabled) }
        set { defaults.set(newValue, forKey: Keys.dailyGoalEnabled) }
    }
    var dailyGoalCount: Int {
        get { defaults.integer(forKey: Keys.dailyGoalCount) == 0 ? 8 : defaults.integer(forKey: Keys.dailyGoalCount) }
        set { defaults.set(newValue, forKey: Keys.dailyGoalCount) }
    }
    var tickingEnabled: Bool {
        get { defaults.bool(forKey: Keys.tickingEnabled) }
        set { defaults.set(newValue, forKey: Keys.tickingEnabled) }
    }
    var notificationVolume: Float {
        get {
            guard defaults.object(forKey: Keys.notificationVolume) != nil else { return 0.7 }
            return defaults.float(forKey: Keys.notificationVolume)
        }
        set { defaults.set(newValue, forKey: Keys.notificationVolume) }
    }

    func resetStreak() {
        defaults.set(0, forKey: Keys.currentStreak)
        defaults.set("", forKey: Keys.lastStreakDate)
    }

    // MARK: - Streak
    var currentStreak: Int {
        get { defaults.integer(forKey: Keys.currentStreak) }
        set { defaults.set(newValue, forKey: Keys.currentStreak) }
    }
    private var lastStreakDate: String {
        get { defaults.string(forKey: Keys.lastStreakDate) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastStreakDate) }
    }

    private func dayKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        // FIX: Keep the day key stable even if the system calendar/region changes (e.g. Buddhist/
        // Japanese calendar); otherwise the streak and weekly stats would "disappear".
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private var todayKey: String { dayKey(Date()) }
    private var yesterdayKey: String {
        dayKey(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
    }

    func checkAndUpdateStreak(dailyWorkCount: Int, goalCount: Int) -> Int {
        guard dailyWorkCount >= goalCount else { return currentStreak }
        let today = todayKey
        guard lastStreakDate != today else { return currentStreak } // already counted today
        currentStreak = (lastStreakDate == yesterdayKey) ? currentStreak + 1 : 1
        lastStreakDate = today
        return currentStreak
    }

    // FIX: "Ghost streak": if the goal was last met neither yesterday nor today, the streak is broken.
    // Called at launch and when the day changes, so the UI never shows a stale value.
    @discardableResult
    func validateStreak() -> Int {
        guard currentStreak > 0 else { return 0 }
        if lastStreakDate != todayKey && lastStreakDate != yesterdayKey {
            currentStreak = 0
        }
        return currentStreak
    }

    // MARK: - Daily stats (for the weekly view)
    private var dailyStats: [String: [String: Int]] {
        get {
            guard let data = defaults.data(forKey: Keys.dailyStats),
                  let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.dailyStats)
            }
        }
    }

    func clearWeeklyStats() {
        defaults.removeObject(forKey: Keys.dailyStats)
    }

    func recordSession(mode: TimerMode) {
        let today = todayKey
        var stats = dailyStats
        var day = stats[today] ?? [:]
        switch mode {
        case .work:       day["w"] = (day["w"] ?? 0) + 1
        case .shortBreak: day["s"] = (day["s"] ?? 0) + 1
        case .longBreak:  day["l"] = (day["l"] ?? 0) + 1
        }
        stats[today] = day
        dailyStats = stats
    }

    func last7DaysStats() -> [(label: String, work: Int, shortBreak: Int, longBreak: Int)] {
        let labelFmt = DateFormatter()
        let locale = LanguageManager.shared.locale
        labelFmt.dateFormat = "EEE"
        labelFmt.locale = locale
        let stats = dailyStats
        return (0..<7).reversed().map { i in
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date()) ?? Date()
            let key = dayKey(date)
            let day = stats[key] ?? [:]
            let label = i == 0 ? L("stats.today") : labelFmt.string(from: date).capitalized(with: locale)
            return (label: label, work: day["w"] ?? 0, shortBreak: day["s"] ?? 0, longBreak: day["l"] ?? 0)
        }
    }

    // Returns true if daily counts were reset
    func checkAndResetDailyCount() -> Bool {
        let today = Date()
        if let lastReset = lastResetDate {
            if !Calendar.current.isDateInToday(lastReset) {
                dailyWorkCount = 0
                dailyShortBreakCount = 0
                dailyLongBreakCount = 0
                lastResetDate = today
                return true
            }
        } else {
            lastResetDate = today
        }
        return false
    }
}

// MARK: - Timer Model
class PomodoroTimer: ObservableObject {
    @Published var minutes: Int = 25
    @Published var seconds: Int = 0
    @Published var isActive: Bool = false
    @Published var mode: TimerMode = .work
    @Published var pomodoroCount: Int = 0
    @Published var dailyWorkCount: Int = 0
    @Published var dailyShortBreakCount: Int = 0
    @Published var dailyLongBreakCount: Int = 0
    @Published var autoStart: Bool = false
    @Published var longBreakInterval: Int = 4
    @Published var extendEnabled: Bool = false
    @Published var twoMinWarning: Bool = false
    @Published var dailyGoalEnabled: Bool = false
    @Published var dailyGoalCount: Int = 8
    @Published var showExtendButton: Bool = false
    @Published var currentStreak: Int = 0
    @Published var tickingEnabled: Bool = false
    @Published var notificationVolume: Float = 0.7
    // FIX: The REAL total duration of the session, for the progress ring.
    // Mode duration in a normal session, 300 s for a +5 min extension. This way the ring
    // doesn't start at 80% when extending and never goes negative for short focus durations.
    @Published var sessionTotalSeconds: Int = 25 * 60

    private var timerSource: DispatchSourceTimer?
    private let settings = SettingsManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var statusItem: NSStatusItem?
    private var tickSoundPlayer: NSSound? = (NSSound(named: "Tink")?.copy() as? NSSound)
    private var twoMinWarnPlayer: NSSound? = (NSSound(named: "Ping")?.copy() as? NSSound)
    private var completionSoundPlayer: NSSound?
    // For the extend button: cancellation mechanism for the 30 s callback.
    // reset/changeMode/extendSession set the token to nil → the pending callback becomes a no-op.
    private var extendToken: UUID?
    // FIX: The timer is now tied to the wall clock. The target end time is stored and the
    // remaining time is computed from it on every tick. So (a) no extra second is counted, (b) ticks
    // lost while the main thread is busy or under App Nap don't stretch the timer.
    private var endDate: Date?
    // The 2-minute warning plays only once per session (not repeated on pause/resume).
    private var twoMinWarned: Bool = false
    // Disables App Nap while the timer runs (system sleep is not prevented).
    private var activityToken: NSObjectProtocol?

    // Window actions are wired up by AppDelegate (routed to MainWindowManager).
    var onToggleWindow: (() -> Void)?
    var onShowWindow: (() -> Void)?

    var workDuration: Int {
        get { settings.workDuration }
        set { settings.workDuration = newValue }
    }

    var shortBreakDuration: Int {
        get { settings.shortBreakDuration }
        set { settings.shortBreakDuration = newValue }
    }

    var longBreakDuration: Int {
        get { settings.longBreakDuration }
        set { settings.longBreakDuration = newValue }
    }

    var notificationSound: String {
        get { settings.notificationSound }
        set { settings.notificationSound = newValue }
    }

    init() {
        pomodoroCount = settings.pomodoroCount
        _ = settings.checkAndResetDailyCount()
        dailyWorkCount = settings.dailyWorkCount
        dailyShortBreakCount = settings.dailyShortBreakCount
        dailyLongBreakCount = settings.dailyLongBreakCount
        autoStart = settings.autoStart
        longBreakInterval = settings.longBreakInterval
        extendEnabled = settings.extendEnabled
        twoMinWarning = settings.twoMinWarning
        dailyGoalEnabled = settings.dailyGoalEnabled
        dailyGoalCount = settings.dailyGoalCount
        // FIX: validate the streak at launch
        currentStreak = settings.validateStreak()
        tickingEnabled = settings.tickingEnabled
        notificationVolume = settings.notificationVolume
        minutes = workDuration
        seconds = 0
        sessionTotalSeconds = workDuration * 60
        requestNotificationPermission()
        setupCancellables()
        // The menu bar icon is no longer created in init; AppDelegate installs it ONCE (installMenuBar).
        setupIdleDetection()
        setupDayChangeDetection()
    }

    deinit {
        timerSource?.cancel()
        timerSource = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Day change detection
    // FIX: If midnight passed while the timer was paused, tick() didn't run and the "Today"
    // counters kept yesterday's values. The system day-change notification fixes this.
    private func setupDayChangeDetection() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDayChanged),
            name: .NSCalendarDayChanged, object: nil)
    }

    @objc private func handleDayChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.applyDayRolloverIfNeeded()
        }
    }

    // If the day changed, resets the daily counters and validates the streak. Single place.
    @discardableResult
    private func applyDayRolloverIfNeeded() -> Bool {
        guard settings.checkAndResetDailyCount() else { return false }
        dailyWorkCount = 0
        dailyShortBreakCount = 0
        dailyLongBreakCount = 0
        currentStreak = settings.validateStreak()
        return true
    }

    // MARK: - Idle / Sleep Detection
    private func setupIdleDetection() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleSystemSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleSystemSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleSystemSleep),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    }

    // Pause directly instead of toggleTimer: if several notifications (sleep/screensSleep/lock)
    // arrive back to back, toggling twice must not restart the timer.
    @objc private func handleSystemSleep() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isActive else { return }
            self.isActive = false
            self.stopTimer()
            self.updateMenuBarButton()
        }
    }

    // MARK: - Menu Bar
    // Idempotent: creates a single icon no matter how many times it's called.
    func installMenuBar() {
        guard statusItem == nil else { return }
        setupMenuBar()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(menuBarClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateMenuBarButton(button: button)
        }
    }

    private func updateMenuBarButton(button: NSStatusBarButton? = nil) {
        let btn = button ?? statusItem?.button
        guard let btn = btn else { return }
        let config = NSImage.SymbolConfiguration(paletteColors: [mode.nsColor])
        btn.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pomodoro")?
            .withSymbolConfiguration(config)
        let isPaused = !isActive && !showExtendButton && totalSeconds > 0 && totalSeconds < sessionTotalSeconds
        let pausePrefix = isPaused ? "⏸ " : ""
        btn.title = " \(pausePrefix)\(String(format: "%02d:%02d", minutes, seconds))"
    }

    @objc private func menuBarClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            onToggleWindow?()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let playPause = NSMenuItem(
            title: isActive ? "⏸  " + L("menu.pause") : "▶  " + L("menu.start"),
            action: #selector(ctxToggle), keyEquivalent: "")
        playPause.target = self
        menu.addItem(playPause)

        let reset = NSMenuItem(title: "↺  " + L("menu.reset"), action: #selector(ctxReset), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        if mode != .work {
            let skip = NSMenuItem(title: "⏭  " + L("menu.skipBreak"), action: #selector(ctxSkip), keyEquivalent: "")
            skip.target = self
            menu.addItem(skip)
        }

        menu.addItem(.separator())

        let about = NSMenuItem(title: L("menu.about"), action: #selector(ctxAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(ctxQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        if let button = statusItem?.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: -1, y: button.bounds.height + 4),
                       in: button)
        }
    }

    @objc private func ctxToggle() { DispatchQueue.main.async { [weak self] in self?.toggleTimer() } }
    @objc private func ctxReset()  { DispatchQueue.main.async { [weak self] in self?.resetTimer() } }
    @objc private func ctxSkip()   { DispatchQueue.main.async { [weak self] in self?.changeMode(to: .work) } }
    @objc private func ctxQuit()   { NSApp.terminate(nil) }
    @objc private func ctxAbout()  { DispatchQueue.main.async { AboutPanel.show() } }

    private func updateMenuBar() {
        DispatchQueue.main.async { [weak self] in
            self?.updateMenuBarButton()
        }
    }

    private func setupCancellables() {
        $pomodoroCount
            .dropFirst()
            .sink { [weak self] count in self?.settings.pomodoroCount = count }
            .store(in: &cancellables)
        $dailyWorkCount
            .dropFirst()
            .sink { [weak self] count in self?.settings.dailyWorkCount = count }
            .store(in: &cancellables)
        $dailyShortBreakCount
            .dropFirst()
            .sink { [weak self] count in self?.settings.dailyShortBreakCount = count }
            .store(in: &cancellables)
        $dailyLongBreakCount
            .dropFirst()
            .sink { [weak self] count in self?.settings.dailyLongBreakCount = count }
            .store(in: &cancellables)
        $autoStart
            .dropFirst()
            .sink { [weak self] val in self?.settings.autoStart = val }
            .store(in: &cancellables)
        $longBreakInterval
            .dropFirst()
            .sink { [weak self] val in self?.settings.longBreakInterval = val }
            .store(in: &cancellables)
        $extendEnabled
            .dropFirst()
            .sink { [weak self] val in self?.settings.extendEnabled = val }
            .store(in: &cancellables)
        $twoMinWarning
            .dropFirst()
            .sink { [weak self] val in self?.settings.twoMinWarning = val }
            .store(in: &cancellables)
        $dailyGoalEnabled
            .dropFirst()
            .sink { [weak self] val in self?.settings.dailyGoalEnabled = val }
            .store(in: &cancellables)
        $dailyGoalCount
            .dropFirst()
            .sink { [weak self] val in self?.settings.dailyGoalCount = val }
            .store(in: &cancellables)
        $tickingEnabled
            .dropFirst()
            .sink { [weak self] val in self?.settings.tickingEnabled = val }
            .store(in: &cancellables)
        $notificationVolume
            .dropFirst()
            .sink { [weak self] val in self?.settings.notificationVolume = val }
            .store(in: &cancellables)
    }

    var totalSeconds: Int { minutes * 60 + seconds }

    // FIX: computed from sessionTotalSeconds and clamped to 0...1.
    var progress: Double {
        let total = sessionTotalSeconds
        guard total > 0 else { return 0 }
        let remaining = min(max(totalSeconds, 0), total)
        return Double(total - remaining) / Double(total)
    }

    var currentModeDuration: Int {
        switch mode {
        case .work: return workDuration
        case .shortBreak: return shortBreakDuration
        case .longBreak: return longBreakDuration
        }
    }

    // Sets the timer to the current mode's duration (start of a new session).
    private func loadFullDuration() {
        seconds = 0
        minutes = currentModeDuration
        sessionTotalSeconds = currentModeDuration * 60
        twoMinWarned = false
    }

    func toggleTimer() {
        // FIX: Pressing Start during the extend window (00:00, +5 min button visible) used to run the
        // timer from 00:00 and repeat the completion (sound + notification) one second later.
        // Now "Start" = count the session, switch to the break and start the break.
        if showExtendButton {
            proceedFromWork()
            if !isActive {
                isActive = true
                startTimer()
            }
            return
        }
        // Defensive: if started at 00:00, start with the full duration
        if !isActive && totalSeconds == 0 {
            loadFullDuration()
        }
        isActive.toggle()
        if isActive {
            startTimer()
        } else {
            stopTimer()
            updateMenuBar()
        }
    }

    func resetTimer() {
        stopTimer()
        isActive = false
        // FIX: Resetting during the extend window must not lose the completed session
        finalizePendingWorkSession()
        loadFullDuration()
        updateMenuBar()
    }

    func changeMode(to newMode: TimerMode) {
        stopTimer()
        isActive = false
        // FIX: Changing mode during the extend window must not lose the completed session
        finalizePendingWorkSession()
        mode = newMode
        loadFullDuration()
        updateMenuBar()
    }

    func selectMode(_ newMode: TimerMode) {
        changeMode(to: newMode)
    }

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Pomodoro timer running")
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func startTimer() {
        stopTimer()
        applyDayRolloverIfNeeded()
        // Compute the target end time from the remaining time
        endDate = Date().addingTimeInterval(TimeInterval(totalSeconds))
        beginActivity()
        let queue = DispatchQueue.global(qos: .userInteractive)
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.tick() }
        }
        source.resume()
        timerSource = source
    }

    private func stopTimer() {
        timerSource?.cancel()
        timerSource = nil
        endDate = nil
        endActivity()
    }

    private func tick() {
        // Ignore a tick left in the queue after the timer was stopped
        guard isActive, let endDate = endDate else { return }

        // Midnight rollover
        applyDayRolloverIfNeeded()

        // FIX: Remaining time is computed from the wall clock (compensates for lost / late ticks)
        let remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        minutes = remaining / 60
        seconds = remaining % 60

        if remaining == 0 {
            handleTimerComplete()
            return
        }

        // Ticking sound: every second in focus mode
        // NSSound.play() is a no-op for a sound that is already playing, so call stop() first
        if tickingEnabled && mode == .work && notificationSound != silentSoundID {
            tickSoundPlayer?.stop()
            tickSoundPlayer?.volume = notificationVolume * 0.35
            tickSoundPlayer?.play()
        }

        // 2-minute warning: if the session is longer than 2 min, once per session
        if twoMinWarning && mode == .work && !twoMinWarned
            && sessionTotalSeconds > 120 && remaining <= 120
            && notificationSound != silentSoundID {
            twoMinWarned = true
            twoMinWarnPlayer?.stop()
            twoMinWarnPlayer?.volume = notificationVolume * 0.7
            twoMinWarnPlayer?.play()
        }

        updateMenuBar()
    }

    private func handleTimerComplete() {
        stopTimer()
        isActive = false
        minutes = 0
        seconds = 0

        let completedMode = mode

        // Play the sound IMMEDIATELY and synchronously, without Task delay
        // FIX: NSSound(named:) returns the SAME shared object every time. If that sound is
        // already playing (e.g. preview in Settings), play() does nothing → no completion sound.
        // A separate copy is used and kept in a property until it finishes playing.
        if notificationSound != silentSoundID {
            completionSoundPlayer?.stop()
            completionSoundPlayer = NSSound(named: notificationSound)?.copy() as? NSSound
            completionSoundPlayer?.volume = notificationVolume
            if completionSoundPlayer?.play() != true {
                NSSound.beep()
            }
        }

        // Send the system notification asynchronously (the sound has already played)
        Task { @MainActor in
            await sendNotification(completedMode: completedMode)
        }

        if mode == .work {
            if extendEnabled {
                // Show the extend button and wait 30 seconds.
                // Token: an identity unique to this wait. If reset/changeMode/extendSession set the token
                // to nil, the guard fails when the asyncAfter callback fires and nothing happens.
                let token = UUID()
                extendToken = token
                showExtendButton = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self = self, self.extendToken == token else { return }
                    self.proceedFromWork()
                }
            } else {
                proceedFromWork()
            }
        } else if mode == .shortBreak {
            dailyShortBreakCount += 1
            settings.recordSession(mode: .shortBreak)
            changeMode(to: .work)
            if autoStart { isActive = true; startTimer() }
        } else {
            dailyLongBreakCount += 1
            settings.recordSession(mode: .longBreak)
            changeMode(to: .work)
            if autoStart { isActive = true; startTimer() }
        }
        updateMenuBar()

        // FIX: Bring the window to front when time is up (there used to be no code for this)
        onShowWindow?()
    }

    // Records a completed focus session in the counters (single place).
    private func recordCompletedWork() {
        pomodoroCount += 1
        dailyWorkCount += 1
        settings.recordSession(mode: .work)
        if dailyGoalEnabled {
            currentStreak = settings.checkAndUpdateStreak(dailyWorkCount: dailyWorkCount, goalCount: dailyGoalCount)
        }
    }

    // If reset/mode change happens while the extend window is open: cancel the pending callback
    // but COUNT the completed focus session.
    private func finalizePendingWorkSession() {
        guard showExtendButton else { return }
        extendToken = nil
        showExtendButton = false
        recordCompletedWork()
    }

    // Finish the focus session and switch to a break.
    private func proceedFromWork() {
        extendToken = nil
        showExtendButton = false
        recordCompletedWork()
        // finalizePendingWorkSession inside changeMode won't count it a second time
        // because showExtendButton is false.
        changeMode(to: pomodoroCount % longBreakInterval == 0 ? .longBreak : .shortBreak)
        if autoStart { isActive = true; startTimer() }
    }

    // The user pressed the +5 min button
    func extendSession() {
        guard showExtendButton else { return }
        // Cancel the pending 30 s callback (the session continues, not counted yet)
        extendToken = nil
        showExtendButton = false
        minutes = 5
        seconds = 0
        sessionTotalSeconds = 5 * 60
        twoMinWarned = false
        isActive = true
        startTimer()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                if let error = error {
                    print("Notification permission error: \(error.localizedDescription)")
                }
            }
    }

    private func sendNotification(completedMode: TimerMode) async {
        // Note: the sound was already played synchronously in handleTimerComplete
        let content = UNMutableNotificationContent()
        content.title = "Pomodoro"
        // 4 messages per mode: notification.<mode>.1 ... notification.<mode>.4
        let prefix: String
        switch completedMode {
        case .work:       prefix = "notification.work."
        case .shortBreak: prefix = "notification.shortBreak."
        case .longBreak:  prefix = "notification.longBreak."
        }
        content.body = L(prefix + String(Int.random(in: 1...4)))
        // .timeSensitive must not be used without the entitlement
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Main App
@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // FIX (double launch): if another copy is running, quit before setting anything up
        SingleInstance.exitIfAnotherInstanceIsRunning()
    }

    var body: some Scene {
        // FIX (double launch): WindowGroup → Window.
        // WindowGroup could open more than one window (clicking the app again /
        // reopen, window restoration). Each window created its own PomodoroTimer and its own
        // menu bar icon → two icons, two timers. Window is single-window.
        Window("Pomodoro", id: "main") {
            ContentView(timer: appDelegate.timer)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    // FIX (double launch): The timer is now owned by AppDelegate, not the view (@StateObject).
    // Even if SwiftUI recreates the view, no second timer / second menu bar icon is created.
    lazy var timer = PomodoroTimer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, menu bar only
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self

        timer.onToggleWindow = { MainWindowManager.shared.toggle() }
        timer.onShowWindow = { MainWindowManager.shared.show() }
        timer.installMenuBar()

        // If a second copy tries to launch, it tells us to "show your window"
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowRequest(_:)),
            name: SingleInstance.showWindowNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleShowRequest(_ note: Notification) {
        Task { @MainActor in MainWindowManager.shared.show() }
    }

    // FIX: Clicking the notification banner brings the window to front (this method used to be
    // missing; the click activated the app but the hidden window didn't appear).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in MainWindowManager.shared.show() }
        completionHandler()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // Show the notification in the foreground too
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    // Keep the app alive when the window closes; it lives in the menu bar
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // When the app is clicked again (Finder/Launchpad/Spotlight), bring back the existing window.
    // FIX (double launch): used to return `true` → SwiftUI opened a new window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowManager.shared.show()
        return false
    }
}

// MARK: - About Panel
// The standard macOS "About" window: icon, name, version, copyright (Info.plist) +
// developer name and clickable GitHub / LinkedIn links.
enum AboutPanel {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: 11)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        func link(_ title: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: title, attributes: [
                .font: font, .link: url, .paragraphStyle: paragraph
            ])
        }

        let credits = NSMutableAttributedString(
            string: LF("about.developedBy", AppInfo.developerName) + "\n", attributes: textAttrs)
        credits.append(link("GitHub", AppInfo.githubURL))
        credits.append(NSAttributedString(string: "  ·  ", attributes: textAttrs))
        credits.append(link("LinkedIn", AppInfo.linkedinURL))

        NSApp.activateAndFocus()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

// MARK: - Content View
struct ContentView: View {
    @ObservedObject var timer: PomodoroTimer
    // Redraw this view (and its texts) when the language changes
    @ObservedObject private var language = LanguageManager.shared
    @State private var showSettings = false
    @State private var showDiscardAlert = false
    @State private var settingsHaveChanges = false

    init(timer: PomodoroTimer) {
        self._timer = ObservedObject(wrappedValue: timer)
    }

    var body: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 0) {
                customTitleBar
                mainContent
            }
            // Keyboard shortcuts: Space start/pause, R reset, Cmd+, settings
            // FIX: Shortcuts without modifiers are active only on the main screen so they don't
            // capture the text fields on the settings screen.
            if !showSettings {
                Button("") { timer.toggleTimer() }
                    .keyboardShortcut(.space, modifiers: [])
                    .opacity(0)
                Button("") { timer.resetTimer() }
                    .keyboardShortcut("r", modifiers: [])
                    .opacity(0)
            }
            Button("") { toggleSettings() }
            .keyboardShortcut(",", modifiers: [.command])
            .opacity(0)
        }
        .frame(width: 600, height: 700)
        .background {
            WindowAccessor { MainWindowManager.shared.register($0) }
        }
        .alert(L("alert.unsaved.title"), isPresented: $showDiscardAlert) {
            Button(L("alert.unsaved.discard"), role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
            }
            Button(L("alert.unsaved.cancel"), role: .cancel) { }
        } message: {
            Text(L("alert.unsaved.message"))
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            Color(red: 0.07, green: 0.09, blue: 0.11)
            RadialGradient(
                colors: [timer.mode.color.opacity(0.08), Color.clear],
                center: .center,
                startRadius: 0,
                endRadius: 320
            )
            .animation(.easeInOut(duration: 0.6), value: timer.mode)
        }
        .ignoresSafeArea()
    }

    private var customTitleBar: some View {
        HStack {
            Spacer()
            Button(action: { toggleSettings() }) {
                Image(systemName: showSettings ? "xmark" : "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.38))
            }
            .buttonStyle(.plain)
            .help(showSettings ? L("help.closeSettings") : L("help.settings"))
            .accessibilityLabel(showSettings ? L("help.closeSettings") : L("help.settings"))
            .padding(.trailing, 20)
        }
        .frame(height: 44)
    }

    private var mainContent: some View {
        VStack(spacing: 24) {
            if showSettings {
                SettingsView(timer: timer, showSettings: $showSettings,
                             hasUnsavedChanges: $settingsHaveChanges)
                    .transition(.opacity)
            } else {
                MainTimerView(timer: timer)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 36)
    }

    // FIX: The "Unsaved Changes" alert used to appear even when NOTHING had changed.
    // Now it only asks when there really are unsaved changes.
    private func toggleSettings() {
        if showSettings {
            if settingsHaveChanges {
                showDiscardAlert = true
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
            }
        } else {
            settingsHaveChanges = false
            withAnimation(.easeInOut(duration: 0.2)) { showSettings = true }
        }
    }
}

// MARK: - Main Timer View
struct MainTimerView: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject private var language = LanguageManager.shared

    var body: some View {
        VStack(spacing: 28) {
            modeSelector
            circularTimer
            controlButtons
            pomodoroCounter
        }
    }

    // Segmented pill control
    private var modeSelector: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0.11))

            // Sliding highlight
            GeometryReader { geo in
                let w = geo.size.width / 3
                let idx: CGFloat = timer.mode == .work ? 0 : timer.mode == .shortBreak ? 1 : 2
                RoundedRectangle(cornerRadius: 11)
                    .fill(timer.mode.color)
                    .frame(width: w - 6, height: 38)
                    .offset(x: idx * w + 3, y: 4)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: timer.mode)
            }

            // Buttons: contentShape gives a full rectangular hit area
            HStack(spacing: 0) {
                ForEach(TimerMode.allCases, id: \.self) { mode in
                    Button(action: { timer.selectMode(mode) }) {
                        Text(mode.displayName)
                            .font(.system(size: 14, weight: timer.mode == mode ? .semibold : .regular))
                            .foregroundColor(timer.mode == mode ? .white : Color(white: 0.45))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 46)
    }

    private var circularTimer: some View {
        ZStack {
            // Glow behind
            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(timer.mode.color.opacity(0.18), lineWidth: 22)
                .frame(width: 300, height: 300)
                .rotationEffect(.degrees(-90))
                .blur(radius: 14)
                .animation(.linear(duration: 1), value: timer.progress)

            // Track
            Circle()
                .stroke(Color(white: 0.16), lineWidth: 6)
                .frame(width: 300, height: 300)

            // Progress
            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(timer.mode.color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 300, height: 300)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: timer.progress)

            // Timer text
            VStack(spacing: 4) {
                Text(timeString)
                    .font(.system(size: 90, weight: .thin))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(timer.mode.displayName.uppercased(with: language.locale))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3)
                    .foregroundColor(timer.mode.color.opacity(0.8))
            }
        }
    }

    private var controlButtons: some View {
        VStack(spacing: 14) {
            HStack(spacing: 20) {
                // Reset: small
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        timer.resetTimer()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color(white: 0.55))
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(Color(white: 0.16)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("menu.reset"))

                // Play/Pause: large and dominant
                Button(action: { timer.toggleTimer() }) {
                    ZStack {
                        Circle()
                            .fill(timer.mode.color)
                            .frame(width: 74, height: 74)
                            .shadow(color: timer.mode.color.opacity(0.4), radius: 12, x: 0, y: 4)
                        Image(systemName: timer.isActive ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(.white)
                            .offset(x: timer.isActive ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(timer.isActive ? L("menu.pause") : L("menu.start"))
                .animation(.easeInOut(duration: 0.15), value: timer.isActive)

                Color.clear.frame(width: 50, height: 50)
            }

            // Skip button in break mode
            if timer.mode != .work {
                Button(action: { timer.changeMode(to: .work) }) {
                    HStack(spacing: 5) {
                        Text(L("main.skipBreak"))
                            .font(.system(size: 13))
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(Color(white: 0.4))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(white: 0.14))
                    )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: timer.mode)
    }

    private var pomodoroCounter: some View {
        VStack(spacing: 10) {
            // Extend button: shown when a focus session ends
            if timer.showExtendButton {
                Button(action: { timer.extendSession() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                        Text(L("main.extend"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.red.opacity(0.8))
                    )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // Dot count follows longBreakInterval, so it's correct when the user picks something other than 4
            HStack(spacing: 10) {
                ForEach(0..<timer.longBreakInterval, id: \.self) { index in
                    Circle()
                        .fill(index < (timer.pomodoroCount % timer.longBreakInterval) ? timer.mode.color : Color(white: 0.2))
                        .frame(width: 7, height: 7)
                        .animation(.spring(response: 0.3), value: timer.pomodoroCount)
                }
            }

            Text(LP("main.todaySummary", count: dailyCountForCurrentMode,
                    dailyCountForCurrentMode, timer.dailyWorkCount * timer.workDuration))
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.35))
                .contentTransition(.numericText())

            // Daily goal
            if timer.dailyGoalEnabled {
                let progress = min(Double(timer.dailyWorkCount) / Double(max(timer.dailyGoalCount, 1)), 1.0)
                VStack(spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.15))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(progress >= 1 ? Color.green : Color.red.opacity(0.7))
                                .frame(width: geo.size.width * progress)
                                .animation(.spring(response: 0.4), value: progress)
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 8) {
                        Text(progress >= 1 ? L("main.goalReached")
                                           : LF("main.goalProgress", timer.dailyWorkCount, timer.dailyGoalCount))
                            .font(.system(size: 11))
                            .foregroundColor(progress >= 1 ? .green : Color(white: 0.35))
                            .contentTransition(.numericText())
                        if timer.currentStreak > 1 {
                            Text(LP("main.streak", count: timer.currentStreak, timer.currentStreak))
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: timer.showExtendButton)
    }

    private var dailyCountForCurrentMode: Int {
        switch timer.mode {
        case .work: return timer.dailyWorkCount
        case .shortBreak: return timer.dailyShortBreakCount
        case .longBreak: return timer.dailyLongBreakCount
        }
    }

    private var timeString: String {
        String(format: "%02d:%02d", timer.minutes, timer.seconds)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject private var language = LanguageManager.shared
    @Binding var showSettings: Bool
    @Binding var hasUnsavedChanges: Bool

    @State private var workDuration: String
    @State private var shortBreakDuration: String
    @State private var longBreakDuration: String
    @State private var selectedSound: String
    @State private var autoStart: Bool
    @State private var launchAtLogin: Bool
    @State private var longBreakIntervalStr: String
    @State private var notificationsDenied: Bool = false
    @State private var extendEnabled: Bool
    @State private var twoMinWarning: Bool
    @State private var dailyGoalEnabled: Bool
    @State private var dailyGoalStr: String
    @State private var tickingEnabled: Bool
    @State private var notificationVolume: Float
    @State private var weeklyStatsID: UUID = UUID()
    // The error key is stored, not the text, so the message follows a language change.
    @State private var validationErrorKey: String = ""

    init(timer: PomodoroTimer, showSettings: Binding<Bool>, hasUnsavedChanges: Binding<Bool>) {
        self.timer = timer
        self._showSettings = showSettings
        self._hasUnsavedChanges = hasUnsavedChanges
        self._workDuration = State(initialValue: String(timer.workDuration))
        self._shortBreakDuration = State(initialValue: String(timer.shortBreakDuration))
        self._longBreakDuration = State(initialValue: String(timer.longBreakDuration))
        self._selectedSound = State(initialValue: timer.notificationSound)
        self._autoStart = State(initialValue: timer.autoStart)
        self._longBreakIntervalStr = State(initialValue: String(timer.longBreakInterval))
        self._extendEnabled = State(initialValue: timer.extendEnabled)
        self._twoMinWarning = State(initialValue: timer.twoMinWarning)
        self._dailyGoalEnabled = State(initialValue: timer.dailyGoalEnabled)
        self._dailyGoalStr = State(initialValue: String(timer.dailyGoalCount))
        self._tickingEnabled = State(initialValue: timer.tickingEnabled)
        self._notificationVolume = State(initialValue: timer.notificationVolume)
        if #available(macOS 13.0, *) {
            self._launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
        } else {
            self._launchAtLogin = State(initialValue: false)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("settings.title"))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white)

                languagePicker

                Group {
                    SettingField(title: L("settings.workDuration"), value: $workDuration)
                    SettingField(title: L("settings.shortBreakDuration"), value: $shortBreakDuration)
                    SettingField(title: L("settings.longBreakDuration"), value: $longBreakDuration)
                    SettingField(title: L("settings.longBreakInterval"), value: $longBreakIntervalStr)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.sound"))
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                    HStack {
                        Picker("", selection: $selectedSound) {
                            ForEach(systemSounds, id: \.self) { s in
                                Text(s == silentSoundID ? L("sound.silent") : s).tag(s)
                            }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        Button(action: {
                            if selectedSound != silentSoundID, let s = NSSound(named: selectedSound) {
                                s.volume = notificationVolume
                                s.play()
                            }
                        }) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 20)).foregroundColor(.white)
                        }.buttonStyle(.plain)
                        .accessibilityLabel(L("settings.previewSound"))
                    }
                    .padding(4)
                    .background(Color(white: 0.2, opacity: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Volume slider
                    if selectedSound != silentSoundID {
                        HStack {
                            Image(systemName: "speaker.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.4))
                            Slider(value: $notificationVolume, in: 0...1, step: 0.05)
                                .tint(.red)
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.4))
                            Text("\(Int(notificationVolume * 100))%")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.4))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }

                toggleRow(title: L("settings.autoStart.title"),
                          subtitle: L("settings.autoStart.subtitle"),
                          isOn: $autoStart)

                toggleRow(title: L("settings.launchAtLogin.title"),
                          subtitle: L("settings.launchAtLogin.subtitle"),
                          isOn: Binding(
                            get: { launchAtLogin },
                            set: { setLaunchAtLogin($0) }
                          ))
                .onAppear {
                    // Sync the toggle with the real system state every time it appears.
                    // With an ad-hoc signed build the registration can silently drop after a rebuild;
                    // this reflects the "looks on but isn't registered" state in the UI.
                    if #available(macOS 13.0, *) {
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }

                toggleRow(title: L("settings.extend.title"),
                          subtitle: L("settings.extend.subtitle"),
                          isOn: $extendEnabled)

                toggleRow(title: L("settings.twoMinWarning.title"),
                          subtitle: L("settings.twoMinWarning.subtitle"),
                          isOn: $twoMinWarning)

                toggleRow(title: L("settings.ticking.title"),
                          subtitle: L("settings.ticking.subtitle"),
                          isOn: $tickingEnabled)

                VStack(spacing: 8) {
                    toggleRow(title: L("settings.dailyGoal.title"),
                              subtitle: L("settings.dailyGoal.subtitle"),
                              isOn: $dailyGoalEnabled)
                    if dailyGoalEnabled {
                        SettingField(title: L("settings.dailyGoal.count"), value: $dailyGoalStr)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: dailyGoalEnabled)

                weeklyStatsView
                    .id(weeklyStatsID)

                if notificationsDenied {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(.orange).font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.notificationsOff.title"))
                                .font(.system(size: 13, weight: .medium)).foregroundColor(.orange)
                            Text(L("settings.notificationsOff.hint"))
                                .font(.system(size: 11)).foregroundColor(Color(white: 0.5))
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !validationErrorKey.isEmpty {
                    Text(L(validationErrorKey))
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                }

                saveButton
                resetCountButton
                aboutSection
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            UNUserNotificationCenter.current().getNotificationSettings { s in
                DispatchQueue.main.async {
                    notificationsDenied = s.authorizationStatus == .denied
                }
            }
        }
        // Report the unsaved-changes state to the parent view
        .task(id: isDirty) { hasUnsavedChanges = isDirty }
    }

    // Does any field differ from the saved values? ("Launch at Login" applies immediately,
    // so it's not included here.)
    private var isDirty: Bool {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return t(workDuration) != String(timer.workDuration)
            || t(shortBreakDuration) != String(timer.shortBreakDuration)
            || t(longBreakDuration) != String(timer.longBreakDuration)
            || t(longBreakIntervalStr) != String(timer.longBreakInterval)
            || selectedSound != timer.notificationSound
            || autoStart != timer.autoStart
            || extendEnabled != timer.extendEnabled
            || twoMinWarning != timer.twoMinWarning
            || tickingEnabled != timer.tickingEnabled
            || notificationVolume != timer.notificationVolume
            || dailyGoalEnabled != timer.dailyGoalEnabled
            || (dailyGoalEnabled && t(dailyGoalStr) != String(timer.dailyGoalCount))
    }

    // Syncs launch at login with the system synchronously: AFTER the register/unregister
    // call, writes the REAL state to the backing state. So if the operation
    // fails, the toggle doesn't lie and snaps back to the correct position automatically.
    // An imperative setter is used instead of onChange: this completely avoids the
    // reentrancy/feedback loop (toggle→onChange→revert→onChange...).
    private func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login error: \(error.localizedDescription)")
        }
        // Success or failure: reflect the real system state.
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(12)
        .background(Color(white: 0.15, opacity: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var weeklyStatsView: some View {
        let stats = SettingsManager.shared.last7DaysStats()
        let maxWork = max(stats.map(\.work).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("stats.last7Days"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    SettingsManager.shared.clearWeeklyStats()
                    weeklyStatsID = UUID()
                }) {
                    Text(L("stats.clear"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(stats, id: \.label) { day in
                    VStack(spacing: 5) {
                        if day.work > 0 {
                            Text("\(day.work)")
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.5))
                        }
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.work > 0 ? Color.red.opacity(0.7) : Color(white: 0.15))
                            .frame(height: max(CGFloat(day.work) / CGFloat(maxWork) * 48, 4))
                        Text(day.label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.35))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 72, alignment: .bottom)
            .padding(12)
            .background(Color(white: 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var saveButton: some View {
        Button(action: saveSettings) {
            Text(L("settings.save"))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green)
                )
        }
        .buttonStyle(.plain)
    }

    private var resetCountButton: some View {
        Button(action: {
            timer.pomodoroCount = 0
            timer.dailyWorkCount = 0
            timer.dailyShortBreakCount = 0
            timer.dailyLongBreakCount = 0
            timer.currentStreak = 0
            SettingsManager.shared.resetStreak()
        }) {
            Text(L("settings.resetCount"))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.3))
                )
        }
        .buttonStyle(.plain)
    }

    // The language choice applies immediately (no Save needed), so it's not part of isDirty.
    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("settings.language"))
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { language.preference },
                set: { language.setPreference($0) }
            )) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.pickerLabel).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Refresh the segment labels (e.g. "System" → "Sistem") when the language changes
            .id(language.code)
        }
    }

    // Developer info and links
    private var aboutSection: some View {
        VStack(spacing: 8) {
            Divider()
                .overlay(Color(white: 0.2))
                .padding(.bottom, 4)
            Text(verbatim: "Pomodoro \(AppInfo.version)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.6))
            Text(LF("about.developedBy", AppInfo.developerName))
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.5))
            HStack(spacing: 16) {
                Link(destination: AppInfo.githubURL) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppInfo.linkedinURL) {
                    Label("LinkedIn", systemImage: "person.crop.circle")
                }
            }
            .font(.system(size: 12))
            Text(AppInfo.copyrightLine)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.35))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func saveSettings() {
        validationErrorKey = ""
        // FIX: Don't reject a valid number because of leading/trailing spaces ("25 ")
        func num(_ s: String) -> Int { Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        let newWork = num(workDuration)
        let newShort = num(shortBreakDuration)
        let newLong = num(longBreakDuration)
        let newInterval = num(longBreakIntervalStr)
        let newGoal = num(dailyGoalStr)

        if newWork <= 0 || newWork > 120 {
            validationErrorKey = "error.workDuration"; return
        }
        if newShort <= 0 || newShort > 60 {
            validationErrorKey = "error.shortBreakDuration"; return
        }
        if newLong <= 0 || newLong > 120 {
            validationErrorKey = "error.longBreakDuration"; return
        }
        if newInterval <= 0 || newInterval > 10 {
            validationErrorKey = "error.longBreakInterval"; return
        }
        if dailyGoalEnabled && (newGoal <= 0 || newGoal > 100) {
            validationErrorKey = "error.dailyGoal"; return
        }

        // FIX: Previously ANY duration change (or the long break interval) reset the running
        // timer. E.g. changing only the break duration while focusing wiped the ongoing
        // focus session. Now it resets only if the CURRENT mode's duration changed.
        let currentModeDurationChanged: Bool
        switch timer.mode {
        case .work:       currentModeDurationChanged = newWork != timer.workDuration
        case .shortBreak: currentModeDurationChanged = newShort != timer.shortBreakDuration
        case .longBreak:  currentModeDurationChanged = newLong != timer.longBreakDuration
        }

        timer.workDuration = newWork
        timer.shortBreakDuration = newShort
        timer.longBreakDuration = newLong
        timer.longBreakInterval = newInterval
        timer.notificationSound = selectedSound
        timer.autoStart = autoStart
        timer.extendEnabled = extendEnabled
        timer.twoMinWarning = twoMinWarning
        timer.tickingEnabled = tickingEnabled
        timer.notificationVolume = notificationVolume
        timer.dailyGoalEnabled = dailyGoalEnabled
        if dailyGoalEnabled && newGoal > 0 { timer.dailyGoalCount = newGoal }

        if currentModeDurationChanged { timer.resetTimer() }
        withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
    }
}

// MARK: - Setting Field
struct SettingField: View {
    let title: String
    @Binding var value: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.secondary)

            TextField("", text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.2, opacity: 0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isFocused ? Color.blue : Color(white: 0.3), lineWidth: 1)
                        )
                )
                .focused($isFocused)
        }
    }
}
