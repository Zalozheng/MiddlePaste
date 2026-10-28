import Cocoa
import ApplicationServices
import ServiceManagement

// 标记：我们自己合成的事件，避免被自己的监听再次处理
let kMarker: Int64 = 0x4D50_4153

// 这些软件里，粘贴前不先合成左键点击（想加别的终端就往里添一行）
let noClickApps: Set<String> = [
    "com.mitchellh.ghostty",   // Ghostty
    // "com.googlecode.iterm2", // iTerm2
    // "com.apple.Terminal",    // 系统自带终端
]

// 这些软件自己处理选中复制和中键，MiddlePaste 完全不插手
let nativeMiddleApps: Set<String> = [
    "com.mitchellh.ghostty",
]

let finderID = "com.apple.finder"

typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

// ============================================================
// 四指轻点触控板 => 应用程序窗口（App Exposé）
// 原理：用系统私有框架 MultitouchSupport 读触点，
// 恰好 4 根手指、很快抬起、基本没移动 = 四指轻点，然后模拟 Control + ↓
// ============================================================
let kMaxTapSeconds = 0.35   // 从落下到全部抬起，超过就不算"轻点"
let kMaxMove: Float = 0.04  // 手指中心移动超过这个比例就算滑动
let kCooldown = 0.40        // 触发后多少秒内不重复触发
let kKeyDownArrow: CGKeyCode = 125

struct MTPoint { var x: Float; var y: Float }
struct MTVector { var position: MTPoint; var velocity: MTPoint }
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerId: Int32
    var handId: Int32
    var normalized: MTVector
    var size: Float
    var pressure: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var density: Float
}

typealias MTContactCallback = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

@_silgen_name("MTDeviceCreateList")
func MTDeviceCreateList() -> Unmanaged<CFArray>?
@_silgen_name("MTRegisterContactFrameCallback")
func MTRegisterContactFrameCallback(_ dev: UnsafeRawPointer, _ cb: MTContactCallback)
@_silgen_name("MTDeviceStart")
func MTDeviceStart(_ dev: UnsafeRawPointer, _ mode: Int32)

// 总开关、四指轻点开关（菜单里控制）
var masterOn = true
var fourTapOn = UserDefaults.standard.object(forKey: "fourTapMode") as? Bool ?? true
var scrollReverseOn = UserDefaults.standard.object(forKey: "scrollReverseMode") as? Bool ?? true

// 四指轻点的状态（只在触控板回调线程里读写）
var ftActive = false
var ftMaxFingers: Int32 = 0
var ftStart = 0.0
var ftHaveBase = false
var ftBaseX: Float = 0
var ftBaseY: Float = 0
var ftMoved = false
var ftLastFire = -10.0
var ftDevices: CFArray?     // 故意一直持有，不释放

func triggerAppExpose() {
    let src = CGEventSource(stateID: .hidSystemState)
    let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]   // 方向键自带的标记
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: kKeyDownArrow, keyDown: down) else { continue }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

func onFrame(_ dev: UnsafeRawPointer?, _ raw: UnsafeMutableRawPointer?, _ n: Int32, _ ts: Double, _ frame: Int32) -> Int32 {
    guard masterOn, fourTapOn, let raw = raw else {
        ftActive = false
        return 0
    }
    let t = raw.assumingMemoryBound(to: MTTouch.self)
    if n > 0 {
        if !ftActive {                         // 新的一轮开始
            ftActive = true
            ftMaxFingers = 0
            ftStart = ts
            ftHaveBase = false
            ftMoved = false
        }
        if n > ftMaxFingers { ftMaxFingers = n }

        if n == 4 {                            // 4 指时记录中心点，看有没有滑动
            var cx: Float = 0, cy: Float = 0
            for i in 0..<4 {
                cx += t[i].normalized.position.x
                cy += t[i].normalized.position.y
            }
            cx /= 4; cy /= 4
            if !ftHaveBase {
                ftBaseX = cx; ftBaseY = cy; ftHaveBase = true
            } else if hypotf(cx - ftBaseX, cy - ftBaseY) > kMaxMove {
                ftMoved = true
            }
        }
    } else if ftActive {                       // 全部抬起 = 这一轮结束
        ftActive = false
        if ftMaxFingers == 4, !ftMoved,
           ts - ftStart < kMaxTapSeconds,
           ts - ftLastFire > kCooldown {
            ftLastFire = ts
            triggerAppExpose()
        }
    }
    return 0
}

// 开机时触控板可能还没就绪，最多等 30 秒，放在后台线程里等
func startFourTap() {
    DispatchQueue.global(qos: .utility).async {
        var list: CFArray?
        for _ in 0..<30 {
            list = MTDeviceCreateList()?.takeUnretainedValue()
            if let l = list, CFArrayGetCount(l) > 0 { break }
            sleep(1)
        }
        guard let l = list, CFArrayGetCount(l) > 0 else { return }
        ftDevices = l
        for i in 0..<CFArrayGetCount(l) {
            if let d = CFArrayGetValueAtIndex(l, i) {
                MTRegisterContactFrameCallback(d, onFrame)
                MTDeviceStart(d, 0)
            }
        }
    }
}

// ============================================================
// 菜单栏主程序
// ============================================================
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    var enabled = true { didSet { masterOn = enabled } }
    var trackpadMode: Bool = UserDefaults.standard.object(forKey: "trackpadMode") as? Bool ?? true
    var autoCopyMode: Bool = UserDefaults.standard.object(forKey: "autoCopyMode") as? Bool ?? true
    var swallowMiddleUp = false
    var lastAction: TimeInterval = 0
    var retryTimer: Timer?
    var toggleItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var trackpadItem: NSMenuItem!
    var autoCopyItem: NSMenuItem!
    var scrollItem: NSMenuItem!
    var fourTapItem: NSMenuItem!

    // 拖选自动复制
    var downPoint: CGPoint = .zero
    var screenshotDrag = false

    // 触控板双指连点（只在 Finder 里）：第一下先"扣住"，看 0.4 秒内有没有第二下
    var pendingRight: (time: TimeInterval, point: CGPoint)?
    var pendingTimer: Timer?
    var swallowRightUps = 0
    let doubleTapWindow: TimeInterval = 0.4

    // MARK: 启动
    func applicationDidFinishLaunching(_ n: Notification) {
        setupMenu()
        enableLoginOnFirstLaunch()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !installTap() {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.installTap() == true { t.invalidate() }
            }
        }
        startFourTap()
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "MiddlePaste") {
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "中键"
        }
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "启用", action: #selector(toggle), keyEquivalent: "")
        toggleItem.state = .on
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        autoCopyItem = NSMenuItem(title: "拖选文字自动复制", action: #selector(toggleAutoCopy), keyEquivalent: "")
        autoCopyItem.state = autoCopyMode ? .on : .off
        menu.addItem(autoCopyItem)
        trackpadItem = NSMenuItem(title: "Finder 里双指连点 = 复制路径", action: #selector(toggleTrackpad), keyEquivalent: "")
        trackpadItem.state = trackpadMode ? .on : .off
        menu.addItem(trackpadItem)
        scrollItem = NSMenuItem(title: "鼠标滚轮反转（触控板不变）", action: #selector(toggleScroll), keyEquivalent: "")
        scrollItem.state = scrollReverseOn ? .on : .off
        menu.addItem(scrollItem)
        fourTapItem = NSMenuItem(title: "四指轻点 = 应用程序窗口", action: #selector(toggleFourTap), keyEquivalent: "")
        fourTapItem.state = fourTapOn ? .on : .off
        menu.addItem(fourTapItem)
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "隐藏菜单栏图标（再打开一次应用可恢复）", action: #selector(hideIcon), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.isVisible = !UserDefaults.standard.bool(forKey: "hideIcon")
    }

    @objc func hideIcon() {
        UserDefaults.standard.set(true, forKey: "hideIcon")
        statusItem.isVisible = false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        UserDefaults.standard.set(false, forKey: "hideIcon")
        statusItem.isVisible = true
        return false
    }

    @objc func toggle() {
        enabled.toggle()
        toggleItem.state = enabled ? .on : .off
    }

    @objc func toggleAutoCopy() {
        autoCopyMode.toggle()
        UserDefaults.standard.set(autoCopyMode, forKey: "autoCopyMode")
        autoCopyItem.state = autoCopyMode ? .on : .off
    }

    @objc func toggleTrackpad() {
        trackpadMode.toggle()
        UserDefaults.standard.set(trackpadMode, forKey: "trackpadMode")
        trackpadItem.state = trackpadMode ? .on : .off
    }

    @objc func toggleScroll() {
        scrollReverseOn.toggle()
        UserDefaults.standard.set(scrollReverseOn, forKey: "scrollReverseMode")
        scrollItem.state = scrollReverseOn ? .on : .off
    }

    @objc func toggleFourTap() {
        fourTapOn.toggle()
        UserDefaults.standard.set(fourTapOn, forKey: "fourTapMode")
        fourTapItem.state = fourTapOn ? .on : .off
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MiddlePaste 开机自启设置失败: \(error)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func enableLoginOnFirstLaunch() {
        let key = "didSetupLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: 事件监听
    func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let d = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            return d.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func frontApp() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == kMarker {
            return Unmanaged.passUnretained(event)
        }
        guard enabled else { return Unmanaged.passUnretained(event) }

        switch type {
        case .scrollWheel:
            // 只反转鼠标滚轮，触控板的滚动是"连续的"（continuous），不动
            if scrollReverseOn,
               event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
                let a = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let p = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
                let f = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -a)
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -p)
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -f)
            }

        case .leftMouseDown:
            downPoint = event.location
            // 正在截图（拖框选区）时，这次拖动不是选文字，完全不要碰
            screenshotDrag = autoCopyMode ? screenshotUIActive() : false

        case .leftMouseUp:
            let p = event.location
            let dist = hypot(p.x - downPoint.x, p.y - downPoint.y)
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            let wasScreenshot = screenshotDrag
            screenshotDrag = false
            // 拖选，或者双击/三击选词
            if autoCopyMode, !wasScreenshot, dist > 4 || clicks >= 2 {
                let front = frontApp()
                if front != finderID, !nativeMiddleApps.contains(front) {
                    // 等软件把选区更新好再复制
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        self?.autoCopySelection()
                    }
                }
            }

        case .otherMouseDown:
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                // 在 Ghostty 等软件里，中键原样放行
                if nativeMiddleApps.contains(frontApp()) {
                    return Unmanaged.passUnretained(event)
                }
                let p = event.location
                swallowMiddleUp = true
                DispatchQueue.main.async { [weak self] in self?.middleAction(at: p) }
                return nil
            }

        case .otherMouseUp:
            if swallowMiddleUp, event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                swallowMiddleUp = false
                return nil
            }

        case .rightMouseDown:
            // 只在 Finder 里处理；其他软件的右键原样放行，没有任何延迟
            guard trackpadMode, frontApp() == finderID else { break }
            let p = event.location
            let now = ProcessInfo.processInfo.systemUptime
            swallowRightUps += 1
            if let first = pendingRight,
               now - first.time < doubleTapWindow,
               hypot(p.x - first.point.x, p.y - first.point.y) < 50 {
                // 第二下来了：复制选中文件的路径
                pendingRight = nil
                pendingTimer?.invalidate()
                DispatchQueue.main.async { [weak self] in self?.copyFinderPaths() }
            } else {
                // 第一下：先扣住，时间到了没第二下，再原样补发一次普通右键
                pendingRight = (now, p)
                pendingTimer?.invalidate()
                pendingTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                    guard let self = self, let first = self.pendingRight else { return }
                    self.pendingRight = nil
                    self.postMouse(.rightMouseDown, at: first.point, button: .right)
                    self.postMouse(.rightMouseUp, at: first.point, button: .right)
                }
            }
            return nil

        case .rightMouseUp:
            if swallowRightUps > 0 {
                swallowRightUps -= 1
                return nil
            }

        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: 拖选自动复制
    func autoCopySelection() {
        // 菜单里"拷贝"是灰的：没选中东西，什么都不做（不按 Cmd+C，不会嘟）
        let menu = copyMenuAvailable()
        if menu == false { return }

        // 查不到菜单：退而求其次，读系统的选区
        if menu == nil {
            if let s = axSelectedText(), !s.isEmpty { setClipboard(s) }
            return
        }

        // 让软件自己按一次 Cmd+C
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        sendKey(8, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard pb.changeCount != before else { return }
            // 复制出来的不是文字（比如图片、对象），就把原来的剪贴板放回去
            if (pb.string(forType: .string) ?? "").isEmpty {
                self?.restore(pb, saved)
            }
        }
    }

    // MARK: 鼠标中键：粘贴（Finder 里是复制路径）
    func middleAction(at p: CGPoint) {
        // 防抖：0.5 秒内的重复触发直接忽略
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAction < 0.5 { return }
        lastAction = now

        let front = frontApp()

        if front == finderID {
            copyFinderPaths()
            return
        }

        // 其他软件：在鼠标位置粘贴剪贴板里的内容
        pasteClipboard(at: p, front: front)
    }

    // Finder：选中了文件/文件夹就复制路径，没选就什么都不做
    func copyFinderPaths() {
        if let paths = finderSelectionPaths(), !paths.isEmpty {
            setClipboard(paths)
        }
    }

    func setClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func pasteClipboard(at p: CGPoint, front: String) {
        // 先在点击位置点一下左键，让光标落到那里；终端类软件跳过
        if !noClickApps.contains(front) {
            postMouse(.leftMouseDown, at: p, button: .left)
            postMouse(.leftMouseUp, at: p, button: .left)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.sendKey(9, flags: .maskCommand)   // V
        }
    }

    // MARK: 读取选区、菜单状态
    // 系统截图界面（Cmd+Shift+4 / 5）开着时，屏幕上会有 screencapture 开头的窗口
    func screenshotUIActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return list.contains { ($0[kCGWindowOwnerName as String] as? String)?.hasPrefix("screencapture") == true }
    }

    func axSelectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success
        else { return nil }
        return sel as? String
    }

    // 检查前台软件菜单栏里的"拷贝"（Cmd+C）当前是否可用；nil 表示查不到
    func copyMenuAvailable() -> Bool? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.2)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXMenuBarAttribute as CFString, &bar) == .success,
              let b = bar else { return nil }
        return findCopyItem(b as! AXUIElement, depth: 0)
    }

    func findCopyItem(_ e: AXUIElement, depth: Int) -> Bool? {
        if depth > 4 { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
              let arr = kids as? [AXUIElement] else { return nil }
        for k in arr {
            var ch: CFTypeRef?
            if AXUIElementCopyAttributeValue(k, "AXMenuItemCmdChar" as CFString, &ch) == .success,
               let s = ch as? String, s.lowercased() == "c" {
                var m: CFTypeRef?
                var mods = 0
                if AXUIElementCopyAttributeValue(k, "AXMenuItemCmdModifiers" as CFString, &m) == .success,
                   let n = m as? Int { mods = n }
                if mods == 0 {
                    var en: CFTypeRef?
                    if AXUIElementCopyAttributeValue(k, kAXEnabledAttribute as CFString, &en) == .success,
                       let ok = en as? Bool { return ok }
                    return true
                }
            }
            if let r = findCopyItem(k, depth: depth + 1) { return r }
        }
        return nil
    }

    // Finder 当前选中的文件/文件夹的完整路径（多个用换行隔开）
    func finderSelectionPaths() -> String? {
        let src = """
        tell application "Finder"
            set sel to selection as alias list
        end tell
        set out to {}
        repeat with a in sel
            set end of out to POSIX path of a
        end repeat
        set AppleScript's text item delimiters to linefeed
        return out as text
        """
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else { return nil }
        let r = script.executeAndReturnError(&err)
        if err != nil { return nil }
        return r.stringValue
    }

    // MARK: 工具函数
    func postMouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.setIntegerValueField(.eventSourceUserData, value: kMarker)
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.post(tap: .cghidEventTap)
    }

    func sendKey(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: kMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    func restore(_ pb: NSPasteboard, _ saved: Snapshot) {
        pb.clearContents()
        let items = saved.map { arr -> NSPasteboardItem in
            let i = NSPasteboardItem()
            for (t, d) in arr { i.setData(d, forType: t) }
            return i
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()