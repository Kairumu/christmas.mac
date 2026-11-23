import AppKit
import ServiceManagement

/// NSStatusItem with the SnowMac menu: intensity, snowplow, wallpapers, reset, quit.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let settings: SettingsStore
    private let overlayManager: OverlayManager
    private let statusItem: NSStatusItem
    private let wallpaperManager = WallpaperManager.shared

    private var intensityMenuItems: [SnowIntensity: NSMenuItem] = [:]
    private var countdownItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    init(settings: SettingsStore, overlayManager: OverlayManager) {
        self.settings = settings
        self.overlayManager = overlayManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.title = "❄️"
        }

        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateCountdown()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateCountdown()
        launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func updateCountdown() {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)

        var christmas = calendar.date(from: DateComponents(year: year, month: 12, day: 25))!
        if startOfToday > christmas {
            christmas = calendar.date(from: DateComponents(year: year + 1, month: 12, day: 25))!
        }
        let startOfChristmas = calendar.startOfDay(for: christmas)

        if startOfToday == startOfChristmas {
            countdownItem.title = "🎄 메리 크리스마스!"
        } else {
            let days = calendar.dateComponents([.day], from: startOfToday, to: startOfChristmas).day ?? 0
            countdownItem.title = "🎄 크리스마스까지 D-\(days)"
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        countdownItem = NSMenuItem(title: "🎄 크리스마스까지 D-?", action: nil, keyEquivalent: "")
        countdownItem.isEnabled = false
        menu.addItem(countdownItem)

        menu.addItem(.separator())

        let intensityMenu = NSMenu()
        for intensity in SnowIntensity.allCases {
            let item = NSMenuItem(title: intensity.rawValue, action: #selector(selectIntensity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = intensity
            item.state = (settings.intensity == intensity) ? .on : .off
            intensityMenuItems[intensity] = item
            intensityMenu.addItem(item)
        }
        let intensityItem = NSMenuItem(title: "눈 양", action: nil, keyEquivalent: "")
        menu.setSubmenu(intensityMenu, for: intensityItem)
        menu.addItem(intensityItem)

        let plowItem = NSMenuItem(title: "제설차 부르기", action: #selector(summonSnowplow), keyEquivalent: "")
        plowItem.target = self
        menu.addItem(plowItem)

        menu.addItem(.separator())

        let wallpaperMenu = NSMenu()
        for i in 1...wallpaperManager.wallpaperCount {
            let item = NSMenuItem(title: "겨울 배경 \(i)", action: #selector(selectWallpaper(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i - 1
            wallpaperMenu.addItem(item)
        }
        let wallpaperItem = NSMenuItem(title: "배경화면", action: nil, keyEquivalent: "")
        menu.setSubmenu(wallpaperMenu, for: wallpaperItem)
        menu.addItem(wallpaperItem)

        let restoreWallpaperItem = NSMenuItem(title: "원래 배경화면 복원", action: #selector(restoreOriginalWallpaper), keyEquivalent: "")
        restoreWallpaperItem.target = self
        menu.addItem(restoreWallpaperItem)

        menu.addItem(.separator())

        let snowOnWindowsItem = NSMenuItem(title: "창 위에 눈 쌓기", action: #selector(toggleSnowOnWindows(_:)), keyEquivalent: "")
        snowOnWindowsItem.target = self
        snowOnWindowsItem.state = settings.snowOnWindows ? .on : .off
        menu.addItem(snowOnWindowsItem)

        let snowOnDockItem = NSMenuItem(title: "Dock 위에 눈 쌓기", action: #selector(toggleSnowOnDock(_:)), keyEquivalent: "")
        snowOnDockItem.target = self
        snowOnDockItem.state = settings.snowOnDock ? .on : .off
        menu.addItem(snowOnDockItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "눈 모두 치우기", action: #selector(clearAllSnow), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let resetItem = NSMenuItem(title: "눈사람 리셋", action: #selector(resetSnowman), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(title: "로그인 시 시작", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "SnowMac 종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func selectIntensity(_ sender: NSMenuItem) {
        guard let intensity = sender.representedObject as? SnowIntensity else { return }
        settings.intensity = intensity
        for (key, item) in intensityMenuItems {
            item.state = (key == intensity) ? .on : .off
        }
    }

    @objc private func summonSnowplow() {
        overlayManager.summonSnowplow()
    }

    @objc private func selectWallpaper(_ sender: NSMenuItem) {
        wallpaperManager.apply(wallpaperIndex: sender.tag)
    }

    @objc private func restoreOriginalWallpaper() {
        wallpaperManager.restoreOriginalWallpapers()
    }

    @objc private func toggleSnowOnWindows(_ sender: NSMenuItem) {
        settings.snowOnWindows.toggle()
        sender.state = settings.snowOnWindows ? .on : .off
    }

    @objc private func toggleSnowOnDock(_ sender: NSMenuItem) {
        settings.snowOnDock.toggle()
        sender.state = settings.snowOnDock ? .on : .off
    }

    @objc private func clearAllSnow() {
        overlayManager.clearAccumulatedSnow()
    }

    @objc private func resetSnowman() {
        overlayManager.resetSnowmen()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            showLaunchAtLoginAlert(message: "SnowMac가 응용 프로그램 폴더에 있지 않습니다.\n응용 프로그램 폴더로 옮긴 후 다시 시도해주세요.")
            sender.state = .off
            return
        }

        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showLaunchAtLoginAlert(message: "로그인 시 시작 설정을 변경하지 못했습니다.\n응용 프로그램 폴더로 옮긴 후 다시 시도해주세요.")
        }
        sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func showLaunchAtLoginAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "로그인 시 시작"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
