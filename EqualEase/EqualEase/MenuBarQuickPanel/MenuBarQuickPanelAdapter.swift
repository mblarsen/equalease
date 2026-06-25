//
//  MenuBarQuickPanelAdapter.swift
//  EqualEase
//

import AppKit
import Combine
import SwiftUI

final class QuickControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class MenuBarQuickPanelAdapter: NSObject, NSWindowDelegate {
    private let appModel: EqualEaseAppModel
    private let openManagementWindow: (SettingsTab) -> Void
    private let openAboutPanel: () -> Void
    private let presentationState = QuickPanelPresentationState()

    private var statusItem: NSStatusItem?
    private var quickPanel: NSPanel?
    private var quickPanelModel: QuickPanelModel<CoreAudioRouter>?
    private var quickPanelLocalEventMonitor: Any?
    private var quickPanelGlobalEventMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var quickPanelCancellables: Set<AnyCancellable> = []
    private var isPositioningQuickPanel = false

    init(
        appModel: EqualEaseAppModel,
        openManagementWindow: @escaping (SettingsTab) -> Void,
        openAboutPanel: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.openManagementWindow = openManagementWindow
        self.openAboutPanel = openAboutPanel
        super.init()
    }

    func install() {
        createStatusItem()
        observeStatusItemState()
    }

    func prewarm() {
        // Keep the hidden quick panel's SwiftUI graph out of the background update path.
        // The panel is cheap enough to create on first presentation and is rebuilt after hide.
    }

    func toggle() {
        if quickPanel?.isVisible == true {
            hide()
            return
        }
        show()
    }

    func show() {
        if quickPanel == nil {
            quickPanel = makeQuickPanel()
        }

        guard let quickPanel else { return }
        appModel.router.refreshOutputDevice()
        appModel.inputDeviceController.refreshInputDevice()
        presentationState.showsPointer = true
        resizeQuickPanelToFitModel()
        positionQuickPanelIfNeeded(quickPanel)
        quickPanel.makeKeyAndOrderFront(nil)
        startDismissMonitoring()
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak quickPanel] in
            guard let quickPanel else { return }
            self?.positionQuickPanelIfNeeded(quickPanel)
        }
    }

    func hide() {
        quickPanel?.orderOut(nil)
        stopDismissMonitoring()
        releaseHiddenQuickPanelSoon()
    }

    func tearDown() {
        stopDismissMonitoring()
        destroyQuickPanel()
        cancellables.removeAll()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
    }

    func windowWillMove(_ notification: Notification) {
        guard !isPositioningQuickPanel,
              notification.object as? NSPanel === quickPanel
        else { return }

        presentationState.showsPointer = false
    }

    private func openManagement(tab: SettingsTab) {
        hide()
        openManagementWindow(tab)
    }

    private func openAbout() {
        hide()
        openAboutPanel()
    }

    private func makeQuickPanelModel() -> QuickPanelModel<CoreAudioRouter> {
        if let quickPanelModel {
            return quickPanelModel
        }

        let actions = QuickPanelActions(
            applyEffectivePreset: { [weak appModel] in
                appModel?.applyEffectivePreset()
            },
            selectPreset: { [weak appModel] presetID in
                appModel?.selectPreset(id: presetID)
            },
            setPresetLock: { [weak appModel] isLocked in
                appModel?.setPresetLock(isLocked)
            },
            acceptAppPresetSuggestion: { [weak appModel] in
                appModel?.acceptAppPresetSuggestion()
            },
            dismissAppPresetSuggestion: { [weak appModel] in
                appModel?.dismissAppPresetSuggestion()
            },
            resetAppPresetSuggestionDismissals: { [weak appModel] in
                appModel?.resetAppPresetSuggestionDismissals()
            },
            openSettingsWindow: { [weak self] in
                self?.openManagement(tab: .general)
            },
            openPresetsSettings: { [weak self] in
                self?.openManagement(tab: .presets)
            },
            showAboutPanel: { [weak self] in
                self?.openAbout()
            },
            quit: {
                NSApplication.shared.terminate(nil)
            }
        )

        let model = QuickPanelModel(
            router: appModel.router,
            inputDeviceController: appModel.inputDeviceController,
            presetStore: appModel.presetStore,
            foregroundAppObserver: appModel.foregroundAppObserver,
            activeContextResolver: appModel.activeContextResolver,
            presentationState: presentationState,
            appVolumeStore: appModel.appVolumeStore,
            audioProcessDiscovery: appModel.audioProcessDiscovery,
            actions: actions
        )
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.resizeQuickPanelToFitModel()
                }
            }
            .store(in: &quickPanelCancellables)
        quickPanelModel = model
        return model
    }

    private func releaseHiddenQuickPanelSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.quickPanel?.isVisible != true else { return }
            self.destroyQuickPanel()
        }
    }

    private func destroyQuickPanel() {
        quickPanelCancellables.removeAll()
        quickPanelModel = nil
        quickPanel?.delegate = nil
        quickPanel?.contentViewController = nil
        quickPanel?.close()
        quickPanel = nil
    }

    private func createStatusItem() {
        guard statusItem == nil else { return }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "EqualEase")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        self.statusItem = statusItem
        updateStatusItemInactiveAppearance()
    }

    private func observeStatusItemState() {
        Publishers.CombineLatest(
            appModel.router.$state.removeDuplicates(),
            appModel.router.$isRoutingTransitioning.removeDuplicates()
        )
        .sink { [weak self] _, _ in
            self?.updateStatusItemInactiveAppearance()
        }
        .store(in: &cancellables)
    }

    private func updateStatusItemInactiveAppearance() {
        guard let button = statusItem?.button else { return }

        let isInactive = appModel.router.state == .stopped
        button.alphaValue = isInactive ? 0.38 : 1.0
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        toggle()
    }

    private func makeQuickPanel() -> NSPanel {
        let model = makeQuickPanelModel()
        let contentView = ContentView(model: model)

        let panel = QuickControlsPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: QuickPanelModel<CoreAudioRouter>.panelWidth,
                height: model.preferredPanelHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "EqualEase"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
        return panel
    }

    private func resizeQuickPanelToFitModel() {
        guard let quickPanel,
              let quickPanelModel
        else { return }

        let currentFrame = quickPanel.frame
        let targetSize = NSSize(
            width: QuickPanelModel<CoreAudioRouter>.panelWidth,
            height: quickPanelModel.preferredPanelHeight
        )
        guard abs(currentFrame.width - targetSize.width) > 0.5
            || abs(currentFrame.height - targetSize.height) > 0.5
        else { return }

        let resizedFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        quickPanel.setFrame(resizedFrame, display: true, animate: false)
        if quickPanel.isVisible {
            positionQuickPanelIfNeeded(quickPanel)
        }
    }

    private func startDismissMonitoring() {
        stopDismissMonitoring()

        quickPanelLocalEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.hideQuickPanelIfEventIsOutside(event)
            return event
        }

        quickPanelGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.hideQuickPanelIfEventIsOutside(event)
        }
    }

    private func stopDismissMonitoring() {
        if let quickPanelLocalEventMonitor {
            NSEvent.removeMonitor(quickPanelLocalEventMonitor)
            self.quickPanelLocalEventMonitor = nil
        }

        if let quickPanelGlobalEventMonitor {
            NSEvent.removeMonitor(quickPanelGlobalEventMonitor)
            self.quickPanelGlobalEventMonitor = nil
        }
    }

    private func hideQuickPanelIfEventIsOutside(_ event: NSEvent) {
        guard let quickPanel, quickPanel.isVisible else {
            stopDismissMonitoring()
            return
        }

        if event.window === quickPanel || eventIsOnStatusItem(event) {
            return
        }

        hide()
    }

    private func eventIsOnStatusItem(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button,
              event.window === button.window
        else { return false }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    private func positionQuickPanelIfNeeded(_ panel: NSPanel) {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main
        else { return }

        let buttonFrameInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = screen.visibleFrame
        let screenFrame = screen.frame
        let panelFrame = panel.frame
        let horizontalEdgeInset: CGFloat = 8
        let verticalGap: CGFloat = 1
        let menuBarReserve = max(min(NSStatusBar.system.thickness, 32), 24)

        // The status-item button's Y coordinate can be unreliable when the menu
        // bar is auto-hidden, Stage Manager is active, or the app is launched
        // from its installed bundle. Use the status item for horizontal
        // anchoring only; vertically pin the borderless panel just below the
        // menu bar so there is no invisible titlebar gap above the content.
        let menuBarBottom = min(visibleFrame.maxY, screenFrame.maxY - menuBarReserve)
        let panelTop = menuBarBottom - verticalGap
        let x = min(
            max(buttonFrameInScreen.midX - panelFrame.width / 2, visibleFrame.minX + horizontalEdgeInset),
            visibleFrame.maxX - panelFrame.width - horizontalEdgeInset
        )
        let y = panelTop - panelFrame.height
        isPositioningQuickPanel = true
        panel.setFrameOrigin(NSPoint(x: x, y: max(y, visibleFrame.minY + horizontalEdgeInset)))
        isPositioningQuickPanel = false
    }
}
