import AppKit
import ApplicationServices

// 初回の案内（U-1）を Koe の部品につなぐ。main.swift からは setUpOnboarding() と、状態の知らせだけを呼ぶ
extension AppDelegate {
    func setUpOnboarding() {
        let o = onboarding
        o.log = { Events.log($0, $1) }
        o.hotkeyCode = { Int(Settings.hotkeyKeyCode) }
        o.setHotkey = { code in
            Settings.defaults.set(code, forKey: "hotkeyKeyCode")
            Events.log("hotkey_changed", ["keyCode": code, "from": "onboarding"])
            self.render()
        }
        o.inputLevel = { [recorder] in recorder.inputLevel }
        // 練習の間だけマイクを開いておく（「マイクを常時待機」がオフの人も）。閉じたら設定どおりに戻す
        o.setWarm = { [recorder] on in recorder.setWarm(on || Settings.warmMic) }
        o.isWarm = { Settings.warmMic }
        o.micNames = { AudioDevices.selectable().map(\.name) }
        o.currentMic = { Settings.micName }
        o.activeMicName = { AudioDevices.inputs().first { $0.id == AudioDevices.defaultInput() }?.name ?? "-" }
        o.selectMic = { [recorder] name in
            Settings.micName = name
            Events.log("mic_selected", ["device": name ?? "auto", "from": "onboarding"])
            recorder.reopen()
            self.render()
        }
        o.openPermission = { [permissionGuide] p in
            permissionGuide.showIfNeeded(reason: "onboarding", manual: true, only: p)
            // アクセシビリティは、一覧に Koe を載せるためにシステムの確認も出す（載っていればスイッチを押すだけになる）
            if p == .accessibility {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            NSWorkspace.shared.open(p.settingsURL)
        }
        // 使うほど賢くする（#168）。オンにするのはメニュー・提案と同じ enableImprove（同意の確認つき）
        o.improveUndecided = { ImproveSuggest.undecided(Settings.defaults) }
        o.improveEnabled = { Settings.improveEnabled }
        o.enableImprove = { [weak self] in self?.enableImprove(via: "onboarding") }
        o.previewImprove = { [weak self] onEmpty in self?.showImprovePreview(via: "onboarding", onEmpty: onEmpty) }
        o.improveReadiness = { done in
            let provider = Settings.improveProvider, command = Settings.improveCommand
            let endpoint = Settings.improveEndpoint, target = Settings.improveTarget
            DispatchQueue.global(qos: .userInitiated).async {
                let r = ImproveReadiness.evaluate(provider: provider, command: command, endpoint: endpoint,
                                                  target: target, found: AppDelegate.loginShellFinds)
                DispatchQueue.main.async { done(r) }
            }
        }
    }

    static func loginShellFinds(_ program: String) -> Bool {
        ImproveCommand.find(program) != nil
    }

    @objc func openOnboarding() { onboarding.show(reason: "menu") }

    // 練習の段では、この画面の上で押したキーを録音に回さない。回さなかったら true
    func onboardingIntercepts(_ e: NSEvent) -> Bool {
        guard onboarding.interceptsHotkey else { return false }
        let key = Settings.hotkeyKeyCode
        if e.type == .flagsChanged, e.keyCode == key, let mask = deviceModifierMask[key] {
            onboarding.hotkey(down: e.modifierFlags.rawValue & mask != 0)
        } else if e.type == .keyDown {
            onboarding.otherKey()
        }
        return true
    }
}
