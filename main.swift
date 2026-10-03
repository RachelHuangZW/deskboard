// DeskBoard —— 常驻桌面的工作台小组件
// 一个无边框、全透明的窗口，固定在屏幕右下角，只出现在指定的那个桌面（默认桌面 1）；
// 层级位于桌面图标之上、普通窗口之下；内容由 index.html 渲染。

import Cocoa
import WebKit

let kLaunchAgentLabel = "local.deskboard"
let kBaseSize = NSSize(width: 1000, height: 600) // 100% 缩放下的尺寸，实际乘以 scale
let kMargin: CGFloat = 12                        // 距屏幕右、下边缘的距离
let kScales: [CGFloat] = [0.6, 0.7, 0.8, 0.9, 1.0]
let kTints: [(String, String)] = [("none", "透明"), ("light", "淡"), ("dark", "深")]

// MARK: - 桌面（Space）
// macOS 没有指定窗口所属桌面的公开接口，这里用系统私有的 CGS 函数（只作用于本应用自己的窗口）
typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ wids: CFArray) -> CFArray
@_silgen_name("CGSAddWindowsToSpaces") func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ wids: CFArray, _ sids: CFArray)
@_silgen_name("CGSRemoveWindowsFromSpaces") func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ wids: CFArray, _ sids: CFArray)

struct Desktop { let id: UInt64; let uuid: String; let number: Int }

// 主屏幕上的普通桌面，按调度中心里「桌面 1、2、3…」的顺序（type 0 为普通桌面，4 为全屏应用）
func listDesktops() -> [Desktop] {
    guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]],
          let main = displays.first else { return [] }
    let spaces = (main["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }
    return spaces.enumerated().compactMap { i, s in
        guard let id = (s["id64"] as? NSNumber)?.uint64Value else { return nil }
        return Desktop(id: id, uuid: s["uuid"] as? String ?? "", number: i + 1)
    }
}

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: WidgetWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var data: [String: String] = [:]
    var alarmTimer: Timer?
    var alarmActivity: NSObjectProtocol?
    var ringItems: [DispatchWorkItem] = []

    let pageURL = Bundle.main.url(forResource: "index", withExtension: "html")!
    let dataURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }()
    let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(kLaunchAgentLabel).plist")

    var pinnedOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "pinnedOnTop") }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedOnTop") }
    }
    var scale: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "scale"); return v > 0 ? v : 0.8 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "scale") }
    }
    // 固定所在桌面的 UUID；未设置时为桌面 1
    var desktopUUID: String? {
        get { UserDefaults.standard.string(forKey: "desktopUUID") }
        set { UserDefaults.standard.set(newValue, forKey: "desktopUUID") }
    }
    // 卡片底色：none / light / dark
    var tint: String {
        get { UserDefaults.standard.string(forKey: "tint") ?? "light" }
        set { UserDefaults.standard.set(newValue, forKey: "tint") }
    }

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadData()
        buildMainMenu()
        buildWindow()
        buildStatusItem()
        // 分辨率 / 显示器 / 程序坞变化后重新贴到右下角
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeWindow() }
        }
        // 切换桌面时校验一次：若目标桌面被删除，会回到桌面 1
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinToDesktop() }
        }
    }

    // MARK: - 数据（~/Library/Application Support/DeskBoard/data.json）

    func loadData() {
        if let raw = try? Data(contentsOf: dataURL),
           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: String] {
            data = obj
        }
    }

    func saveData() {
        if let raw = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? raw.write(to: dataURL, options: .atomic)
        }
    }

    // MARK: - 窗口

    // 固定在主屏幕可见区域（不含菜单栏和程序坞）的右下角
    func anchoredFrame() -> NSRect {
        let screen = (NSScreen.screens.first ?? NSScreen.main!).visibleFrame // 主屏幕（带菜单栏的那块）
        let w = kBaseSize.width * scale, h = kBaseSize.height * scale
        return NSRect(x: screen.maxX - w - kMargin, y: screen.minY + kMargin, width: w, height: h)
    }

    func placeWindow() { window.setFrame(anchoredFrame(), display: true) }

    func buildWindow() {
        window = WidgetWindow(contentRect: anchoredFrame(), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isMovable = false
        // 不加 .canJoinAllSpaces：窗口只属于一个桌面，见 pinToDesktop()
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.appearance = NSAppearance(named: .darkAqua)

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "deskboard")
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: NSRect(origin: .zero, size: window.frame.size), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        webView.pageZoom = scale
        webView.navigationDelegate = self
        window.contentView = webView
        loadPage()

        applyLevel()
        window.orderFrontRegardless()
        pinToDesktop()
    }

    func targetDesktop() -> Desktop? {
        let all = listDesktops()
        return all.first { $0.uuid == desktopUUID } ?? all.first
    }

    // 把窗口放进目标桌面，并从其他桌面移除
    func pinToDesktop() {
        guard let target = targetDesktop() else { return }
        let cid = CGSMainConnectionID()
        let wids = [NSNumber(value: window.windowNumber)] as CFArray
        let current = CGSCopySpacesForWindows(cid, 0x7, wids) as? [NSNumber] ?? []
        if current.map(\.uint64Value) == [target.id] { return }
        CGSAddWindowsToSpaces(cid, wids, [NSNumber(value: target.id)] as CFArray)
        let others = current.filter { $0.uint64Value != target.id }
        if !others.isEmpty { CGSRemoveWindowsFromSpaces(cid, wids, others as CFArray) }
    }

    func setScale(_ newScale: CGFloat) {
        scale = newScale
        placeWindow()
        webView.pageZoom = newScale
    }

    func setTint(_ value: String) {
        tint = value
        webView.evaluateJavaScript("window.__deskboardSetTint && window.__deskboardSetTint('\(value)')")
    }

    // 每次加载前把最新数据注入页面
    func loadPage() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        let json = (try? JSONSerialization.data(withJSONObject: data)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        ucc.addUserScript(WKUserScript(source: "window.__DESKBOARD__ = { data: \(json), tint: '\(tint)' };",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    // 桌面层：在桌面图标之上、所有普通窗口之下；置顶：浮在所有窗口之上
    func applyLevel() {
        window.level = pinnedOnTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        webView.evaluateJavaScript("window.__deskboardPinned && window.__deskboardPinned(\(pinnedOnTop))")
    }

    // MARK: - 菜单

    func buildMainMenu() {
        // 无 Dock 图标的应用也需要编辑菜单，⌘C / ⌘V / ⌘A / ⌘Z 才能在输入框里生效
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 DeskBoard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "DeskBoard") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "☑︎"
        }
        let menu = NSMenu()
        menu.delegate = self
        let desktopItem = NSMenuItem(title: "固定在桌面", action: nil, keyEquivalent: "")
        desktopItem.submenu = NSMenu() // 桌面列表在每次打开菜单时刷新
        menu.addItem(desktopItem)
        menu.addItem(item("置于所有窗口之上", #selector(togglePinned)))

        let scaleMenu = NSMenu()
        for s in kScales {
            let it = item("\(Int((s * 100).rounded()))%", #selector(pickScale(_:)))
            it.representedObject = s
            scaleMenu.addItem(it)
        }
        let scaleItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        scaleItem.submenu = scaleMenu
        menu.addItem(scaleItem)

        let tintMenu = NSMenu()
        for (value, title) in kTints {
            let it = item(title, #selector(pickTint(_:)))
            it.representedObject = value
            tintMenu.addItem(it)
        }
        let tintItem = NSMenuItem(title: "卡片底色", action: nil, keyEquivalent: "")
        tintItem.submenu = tintMenu
        menu.addItem(tintItem)

        menu.addItem(item("重新载入", #selector(reloadPage)))
        menu.addItem(.separator())
        menu.addItem(item("开机自动启动", #selector(toggleLaunchAtLogin)))
        menu.addItem(item("打开数据文件夹", #selector(openDataFolder)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.item(withTitle: "置于所有窗口之上")?.state = pinnedOnTop ? .on : .off
            menu.item(withTitle: "开机自动启动")?.state =
                FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
            for it in menu.item(withTitle: "缩放")?.submenu?.items ?? [] {
                it.state = abs((it.representedObject as? CGFloat ?? 0) - scale) < 0.01 ? .on : .off
            }
            for it in menu.item(withTitle: "卡片底色")?.submenu?.items ?? [] {
                it.state = (it.representedObject as? String) == tint ? .on : .off
            }
            if let sub = menu.item(withTitle: "固定在桌面")?.submenu {
                sub.removeAllItems()
                let target = targetDesktop()
                for d in listDesktops() {
                    let it = item("桌面 \(d.number)", #selector(pickDesktop(_:)))
                    it.representedObject = d.uuid
                    it.state = d.id == target?.id ? .on : .off
                    sub.addItem(it)
                }
            }
        }
    }

    @objc func pickDesktop(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        desktopUUID = uuid
        pinToDesktop()
    }

    @objc func togglePinned() {
        pinnedOnTop.toggle()
        applyLevel()
    }

    @objc func pickScale(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? CGFloat { setScale(s) }
    }

    @objc func pickTint(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String { setTint(v) }
    }

    @objc func reloadPage() { loadPage() }

    @objc func openDataFolder() {
        NSWorkspace.shared.open(dataURL.deletingLastPathComponent())
    }

    @objc func toggleLaunchAtLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentURL.path) {
            try? fm.removeItem(at: launchAgentURL)
            return
        }
        let plist: [String: Any] = [
            "Label": kLaunchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        do {
            try fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let raw = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try raw.write(to: launchAgentURL, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - 倒计时提示音（由原生定时，窗口被遮挡或在后台时也能准点响）

    func scheduleAlarm(at epoch: Double) {
        cancelAlarm()
        let timer = Timer(fire: Date(timeIntervalSince1970: epoch), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.alarmFired() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        alarmTimer = timer
        // 防止 App Nap 推迟定时器
        alarmActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Countdown timer")
    }

    func cancelAlarm() {
        alarmTimer?.invalidate()
        alarmTimer = nil
        if let a = alarmActivity { ProcessInfo.processInfo.endActivity(a) }
        alarmActivity = nil
        ringItems.forEach { $0.cancel() }
        ringItems = []
    }

    func alarmFired() {
        cancelAlarm()
        ring(times: 3)
        webView.evaluateJavaScript("window.__deskboardWake && window.__deskboardWake()")
    }

    func ring(times: Int) {
        for i in 0..<times {
            let work = DispatchWorkItem { NSSound(named: "Glass")?.play() }
            ringItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.6, execute: work)
        }
    }

    // MARK: - JS 消息

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { handle(message.body) }
    }

    func handle(_ body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "set":
            guard let key = body["key"] as? String, let json = body["json"] as? String else { return }
            data[key] = json
            saveData()
        case "alarm":
            if let at = body["at"] as? Double { scheduleAlarm(at: at / 1000) } else { cancelAlarm() }
        case "chime":
            ring(times: 1)
        case "theme":
            window.appearance = NSAppearance(named: (body["value"] as? String) == "light" ? .aqua : .darkAqua)
        case "pin":
            togglePinned()
        default:
            break
        }
    }

    // MARK: - 导航（只允许加载自身页面，拖入文件不会跳走）

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            decisionHandler(action.request.url?.path == pageURL.path ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { applyLevel() }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { loadPage() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
