import AppKit

// Brief post-paste note. Never activates the app or intercepts input.
final class ExpectationHint {
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    func show() {
        hide()
        guard let screen = NSScreen.main else { return }
        let label = NSTextField(labelWithString: OnboardingFlow.hint)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView?.addSubview(label)
        label.frame = NSRect(x: 12, y: 12, width: 406, height: 18)
        p.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 215, y: screen.visibleFrame.maxY - 60))
        p.orderFrontRegardless()
        panel = p
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func update(recording: Bool) {
        if recording { hide() }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
