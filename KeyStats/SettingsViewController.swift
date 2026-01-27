import Cocoa
import PostHog

class SettingsViewController: NSViewController, NSTextFieldDelegate {

    private var appIconView: NSImageView!
    private var showKeyPressesButton: NSButton!
    private var showMouseClicksButton: NSButton!
    private var appStatsEnabledButton: NSButton!
    private var launchAtLoginButton: NSButton!
    private var dynamicIconColorButton: NSButton!
    private var dynamicIconColorStylePopUp: NSPopUpButton!
    private var dynamicIconColorStyleRow: NSStackView!
    private var dynamicIconColorWindowField: NSTextField!
    private var dynamicIconColorWindowRow: NSStackView!
    private var dynamicIconColorHelpButton: NSButton!
    private lazy var dynamicIconColorHelpPopover: NSPopover = makeDynamicIconColorHelpPopover()
    private weak var dynamicIconColorHelpContentView: NSView?
    private var helpButtonTrackingArea: NSTrackingArea?
    private var helpPopoverTrackingArea: NSTrackingArea?
    private var isHoveringHelpButton = false
    private var isHoveringHelpPopover = false
    private var resetButton: NSButton!
    private var exportButton: NSButton!
    private var showThresholdsButton: NSButton!
    private var thresholdStack: NSStackView!
    private var keyPressThresholdField: NSTextField!
    private var keyPressThresholdStepper: NSStepper!
    private var clickThresholdField: NSTextField!
    private var clickThresholdStepper: NSStepper!

    private let thresholdMinimum = 0
    private let thresholdMaximum = 1_000_000
    private let thresholdStep = 100.0
    private let dynamicIconColorStyleKey = "dynamicIconColorStyle"

    private lazy var thresholdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: thresholdMinimum)
        formatter.maximum = NSNumber(value: thresholdMaximum)
        return formatter
    }()
    
    private lazy var windowFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: 1)
        formatter.maximum = NSNumber(value: 3600)
        return formatter
    }()

    private lazy var exportFileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        let mainView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
        mainView.wantsLayer = true
        view = mainView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateState()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateHelpButtonTrackingArea()
        updateHelpPopoverTrackingArea()
    }

    // MARK: - UI

    private func setupUI() {
        appIconView = NSImageView()
        appIconView.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(appIconView)

        showKeyPressesButton = NSButton(checkboxWithTitle: NSLocalizedString("setting.showKeyPresses", comment: ""),
                                        target: self,
                                        action: #selector(toggleShowKeyPresses))

        showMouseClicksButton = NSButton(checkboxWithTitle: NSLocalizedString("setting.showMouseClicks", comment: ""),
                                         target: self,
                                         action: #selector(toggleShowMouseClicks))

        appStatsEnabledButton = NSButton(checkboxWithTitle: NSLocalizedString("setting.appStatsEnabled", comment: ""),
                                         target: self,
                                         action: #selector(toggleAppStatsEnabled))

        launchAtLoginButton = NSButton(checkboxWithTitle: NSLocalizedString("button.launchAtLogin", comment: ""),
                                       target: self,
                                       action: #selector(toggleLaunchAtLogin))

        showThresholdsButton = NSButton(checkboxWithTitle: NSLocalizedString("setting.notificationsEnabled", comment: ""),
                                        target: self,
                                        action: #selector(toggleShowThresholds))

        dynamicIconColorButton = NSButton(checkboxWithTitle: NSLocalizedString("settings.dynamicIconColor", comment: ""),
                                          target: self,
                                          action: #selector(toggleDynamicIconColor))

        dynamicIconColorHelpButton = NSButton()
        dynamicIconColorHelpButton.bezelStyle = .helpButton
        dynamicIconColorHelpButton.title = ""
        dynamicIconColorHelpButton.controlSize = .mini
        dynamicIconColorHelpButton.translatesAutoresizingMaskIntoConstraints = false
        dynamicIconColorHelpButton.widthAnchor.constraint(equalToConstant: 12).isActive = true
        dynamicIconColorHelpButton.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let dynamicIconColorRow = NSStackView(views: [dynamicIconColorButton, dynamicIconColorHelpButton])
        dynamicIconColorRow.orientation = .horizontal
        dynamicIconColorRow.alignment = .centerY
        dynamicIconColorRow.spacing = 6
        dynamicIconColorRow.translatesAutoresizingMaskIntoConstraints = false

        dynamicIconColorStylePopUp = NSPopUpButton()
        let iconStyleTitle = NSLocalizedString("settings.dynamicIconColorStyle.icon", comment: "")
        let dotStyleTitle = NSLocalizedString("settings.dynamicIconColorStyle.dot", comment: "")
        dynamicIconColorStylePopUp.addItems(withTitles: [iconStyleTitle, dotStyleTitle])
        dynamicIconColorStylePopUp.item(at: 0)?.representedObject = DynamicIconColorStyle.icon.rawValue
        dynamicIconColorStylePopUp.item(at: 1)?.representedObject = DynamicIconColorStyle.dot.rawValue
        dynamicIconColorStylePopUp.target = self
        dynamicIconColorStylePopUp.action = #selector(dynamicIconColorStyleChanged)

        let styleLabel = NSTextField(labelWithString: NSLocalizedString("settings.dynamicIconColorStyle", comment: ""))
        styleLabel.font = NSFont.systemFont(ofSize: 13)
        let styleRow = NSStackView(views: [styleLabel, dynamicIconColorStylePopUp])
        styleRow.orientation = .horizontal
        styleRow.alignment = .centerY
        styleRow.spacing = 8
        styleRow.translatesAutoresizingMaskIntoConstraints = false
        dynamicIconColorStyleRow = styleRow

        let windowLabel = NSTextField(labelWithString: NSLocalizedString("settings.dynamicIconColorWindow", comment: ""))
        windowLabel.font = NSFont.systemFont(ofSize: 13)
        
        dynamicIconColorWindowField = NSTextField()
        dynamicIconColorWindowField.formatter = windowFormatter
        dynamicIconColorWindowField.target = self
        dynamicIconColorWindowField.action = #selector(dynamicIconColorWindowChanged)
        dynamicIconColorWindowField.delegate = self
        dynamicIconColorWindowField.translatesAutoresizingMaskIntoConstraints = false
        dynamicIconColorWindowField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        
        let windowRow = NSStackView(views: [windowLabel, dynamicIconColorWindowField])
        windowRow.orientation = .horizontal
        windowRow.alignment = .centerY
        windowRow.spacing = 8
        windowRow.translatesAutoresizingMaskIntoConstraints = false
        dynamicIconColorWindowRow = windowRow

        let optionsStack = NSStackView(views: [showKeyPressesButton, showMouseClicksButton, appStatsEnabledButton, launchAtLoginButton, dynamicIconColorRow, styleRow, windowRow, showThresholdsButton])
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8
        optionsStack.translatesAutoresizingMaskIntoConstraints = false
 
        keyPressThresholdField = makeThresholdField()
        keyPressThresholdStepper = makeThresholdStepper(action: #selector(keyPressThresholdStepperChanged))
        clickThresholdField = makeThresholdField()
        clickThresholdStepper = makeThresholdStepper(action: #selector(clickThresholdStepperChanged))

        let keyThresholdRow = makeThresholdRow(
            title: NSLocalizedString("setting.notifyKeyThreshold", comment: ""),
            field: keyPressThresholdField,
            stepper: keyPressThresholdStepper
        )
        let clickThresholdRow = makeThresholdRow(
            title: NSLocalizedString("setting.notifyClickThreshold", comment: ""),
            field: clickThresholdField,
            stepper: clickThresholdStepper
        )

        thresholdStack = NSStackView(views: [keyThresholdRow, clickThresholdRow])
        thresholdStack.orientation = .vertical
        thresholdStack.alignment = .leading
        thresholdStack.spacing = 6
        thresholdStack.translatesAutoresizingMaskIntoConstraints = false
        
        resetButton = NSButton(title: NSLocalizedString("button.reset", comment: ""), target: self, action: #selector(resetStats))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular

        exportButton = NSButton(title: NSLocalizedString("button.exportData", comment: ""), target: self, action: #selector(exportData))
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .regular

        let actionRow = NSStackView(views: [resetButton, exportButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.distribution = .fillProportionally
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [optionsStack, thresholdStack, actionRow])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)


        NSLayoutConstraint.activate([
            appIconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            appIconView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            appIconView.widthAnchor.constraint(equalToConstant: 48),
            appIconView.heightAnchor.constraint(equalToConstant: 48),

            contentStack.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
    }

    // MARK: - State

    private func updateState() {
        showKeyPressesButton.state = StatsManager.shared.showKeyPressesInMenuBar ? .on : .off
        showMouseClicksButton.state = StatsManager.shared.showMouseClicksInMenuBar ? .on : .off
        appStatsEnabledButton.state = StatsManager.shared.appStatsEnabled ? .on : .off
        launchAtLoginButton.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        dynamicIconColorButton.state = StatsManager.shared.enableDynamicIconColor ? .on : .off
        updateDynamicIconColorStyleSelection()
        let notificationsEnabled = StatsManager.shared.notificationsEnabled
        showThresholdsButton.state = notificationsEnabled ? .on : .off
        thresholdStack.isHidden = !notificationsEnabled
        updateThresholdUI()
    }

    private func updateDynamicIconColorStyleSelection() {
        let styleValue = UserDefaults.standard.string(forKey: dynamicIconColorStyleKey) ?? DynamicIconColorStyle.icon.rawValue
        let style = DynamicIconColorStyle(rawValue: styleValue) ?? .icon
        if let item = dynamicIconColorStylePopUp.itemArray.first(where: { ($0.representedObject as? String) == style.rawValue }) {
            dynamicIconColorStylePopUp.select(item)
        }
        let isEnabled = StatsManager.shared.enableDynamicIconColor
        dynamicIconColorStylePopUp.isEnabled = isEnabled
        dynamicIconColorStyleRow.isHidden = !isEnabled
        
        dynamicIconColorWindowRow.isHidden = !isEnabled
        dynamicIconColorWindowField.doubleValue = StatsManager.shared.dynamicIconColorWindow
    }

    private func makeDynamicIconColorHelpPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = makeDynamicIconColorHelpViewController()
        return popover
    }

    private func makeDynamicIconColorHelpViewController() -> NSViewController {
        let viewController = NSViewController()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        viewController.view = container
        dynamicIconColorHelpContentView = container
        updateHelpPopoverTrackingArea()

        let titleLabel = NSTextField(labelWithString: NSLocalizedString("settings.dynamicIconColorHelp.title", comment: ""))
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("settings.dynamicIconColorHelp.body", comment: ""))
        bodyLabel.font = NSFont.systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        let imageGridStack = NSStackView()
        imageGridStack.orientation = .vertical
        imageGridStack.alignment = .centerX
        imageGridStack.spacing = 8
        imageGridStack.translatesAutoresizingMaskIntoConstraints = false

        let imageNames = [
            "DynamicColorTip3",
            "DynamicColorTip2",
            "DynamicColorTip1",
            "DynamicColorTip6",
            "DynamicColorTip5",
            "DynamicColorTip4"
        ]
        var currentRow: NSStackView?
        for (index, name) in imageNames.enumerated() {
            if index % 3 == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 8
                row.translatesAutoresizingMaskIntoConstraints = false
                imageGridStack.addArrangedSubview(row)
                currentRow = row
            }
            guard let image = NSImage(named: name) else { continue }
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 64).isActive = true
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 44).isActive = true
            currentRow?.addArrangedSubview(imageView)
        }

        let contentStack = NSStackView(views: [titleLabel, bodyLabel, imageGridStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        return viewController
    }

    private func updateHelpButtonTrackingArea() {
        if let trackingArea = helpButtonTrackingArea {
            dynamicIconColorHelpButton.removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: dynamicIconColorHelpButton.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["dynamicIconColorHelpButton": true]
        )
        dynamicIconColorHelpButton.addTrackingArea(trackingArea)
        helpButtonTrackingArea = trackingArea
    }

    private func updateHelpPopoverTrackingArea() {
        guard let container = dynamicIconColorHelpContentView else { return }
        if let trackingArea = helpPopoverTrackingArea {
            container.removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["dynamicIconColorHelpPopover": true]
        )
        container.addTrackingArea(trackingArea)
        helpPopoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["dynamicIconColorHelpButton"] as? Bool == true {
            isHoveringHelpButton = true
            showDynamicIconColorHelpPopover()
            return
        }
        if event.trackingArea?.userInfo?["dynamicIconColorHelpPopover"] as? Bool == true {
            isHoveringHelpPopover = true
            return
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["dynamicIconColorHelpButton"] as? Bool == true {
            isHoveringHelpButton = false
            scheduleHelpPopoverCloseIfNeeded()
            return
        }
        if event.trackingArea?.userInfo?["dynamicIconColorHelpPopover"] as? Bool == true {
            isHoveringHelpPopover = false
            scheduleHelpPopoverCloseIfNeeded()
            return
        }
        super.mouseExited(with: event)
    }

    private func showDynamicIconColorHelpPopover() {
        guard let button = dynamicIconColorHelpButton else { return }
        if dynamicIconColorHelpPopover.isShown { return }
        dynamicIconColorHelpPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func scheduleHelpPopoverCloseIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            if !self.isHoveringHelpButton && !self.isHoveringHelpPopover {
                self.dynamicIconColorHelpPopover.performClose(nil)
            }
        }
    }

    // MARK: - 通知阈值

    private enum ThresholdType {
        case keyPress
        case click
    }

    private func makeThresholdField() -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.formatter = thresholdFormatter
        field.target = self
        field.action = #selector(thresholdFieldEdited)
        field.delegate = self
        return field
    }

    private func makeThresholdStepper(action: Selector) -> NSStepper {
        let stepper = NSStepper()
        stepper.minValue = Double(thresholdMinimum)
        stepper.maxValue = Double(thresholdMaximum)
        stepper.increment = thresholdStep
        stepper.target = self
        stepper.action = action
        return stepper
    }

    private func makeThresholdRow(title: String, field: NSTextField, stepper: NSStepper) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13)

        let unitLabel = NSTextField(labelWithString: NSLocalizedString("setting.notifyUnit", comment: ""))
        unitLabel.textColor = .secondaryLabelColor

        field.translatesAutoresizingMaskIntoConstraints = false
        stepper.translatesAutoresizingMaskIntoConstraints = false

        field.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let row = NSStackView(views: [titleLabel, field, unitLabel, stepper])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func updateThresholdUI() {
        let keyThreshold = StatsManager.shared.keyPressNotifyThreshold
        let clickThreshold = StatsManager.shared.clickNotifyThreshold
        keyPressThresholdField.stringValue = "\(keyThreshold)"
        clickThresholdField.stringValue = "\(clickThreshold)"
        keyPressThresholdStepper.integerValue = keyThreshold
        clickThresholdStepper.integerValue = clickThreshold
    }

    private func clampThreshold(_ value: Int) -> Int {
        return min(max(value, thresholdMinimum), thresholdMaximum)
    }

    private func applyThreshold(_ value: Int, for type: ThresholdType) {
        let clamped = clampThreshold(value)
        switch type {
        case .keyPress:
            if StatsManager.shared.keyPressNotifyThreshold != clamped {
                StatsManager.shared.keyPressNotifyThreshold = clamped
            }
            keyPressThresholdField.stringValue = "\(clamped)"
            keyPressThresholdStepper.integerValue = clamped
        case .click:
            if StatsManager.shared.clickNotifyThreshold != clamped {
                StatsManager.shared.clickNotifyThreshold = clamped
            }
            clickThresholdField.stringValue = "\(clamped)"
            clickThresholdStepper.integerValue = clamped
        }
        requestNotificationPermissionIfNeeded()
    }

    private func requestNotificationPermissionIfNeeded() {
        let manager = StatsManager.shared
        guard manager.notificationsEnabled else { return }
        guard manager.keyPressNotifyThreshold > 0 || manager.clickNotifyThreshold > 0 else { return }
        NotificationManager.shared.requestAuthorizationIfNeeded()
    }

    @objc private func keyPressThresholdStepperChanged() {
        applyThreshold(keyPressThresholdStepper.integerValue, for: .keyPress)
    }

    @objc private func clickThresholdStepperChanged() {
        applyThreshold(clickThresholdStepper.integerValue, for: .click)
    }

    @objc private func dynamicIconColorWindowChanged(_ sender: NSTextField) {
        let value = windowFormatter.number(from: sender.stringValue)?.doubleValue ?? 3.0
        StatsManager.shared.dynamicIconColorWindow = value
    }

    @objc private func thresholdFieldEdited(_ sender: NSTextField) {
        let value = thresholdFormatter.number(from: sender.stringValue)?.intValue ?? 0
        if sender == keyPressThresholdField {
            applyThreshold(value, for: .keyPress)
        } else if sender == clickThresholdField {
            applyThreshold(value, for: .click)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field == dynamicIconColorWindowField {
            dynamicIconColorWindowChanged(field)
        } else {
            thresholdFieldEdited(field)
        }
    }

    // MARK: - Actions

    @objc private func toggleShowThresholds() {
        let enabled = showThresholdsButton.state == .on
        StatsManager.shared.notificationsEnabled = enabled
        thresholdStack.isHidden = !enabled
        if enabled {
            requestNotificationPermissionIfNeeded()
        }
    }

    @objc private func toggleShowKeyPresses() {
        StatsManager.shared.showKeyPressesInMenuBar = (showKeyPressesButton.state == .on)
    }

    @objc private func toggleShowMouseClicks() {
        StatsManager.shared.showMouseClicksInMenuBar = (showMouseClicksButton.state == .on)
    }

    @objc private func toggleAppStatsEnabled() {
        StatsManager.shared.appStatsEnabled = (appStatsEnabledButton.state == .on)
    }

    @objc private func toggleDynamicIconColor() {
        StatsManager.shared.enableDynamicIconColor = dynamicIconColorButton.state == .on
        updateDynamicIconColorStyleSelection()
    }

    @objc private func dynamicIconColorStyleChanged() {
        guard let rawValue = dynamicIconColorStylePopUp.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(rawValue, forKey: dynamicIconColorStyleKey)
        StatsManager.shared.menuBarUpdateHandler?()
    }

    @objc private func toggleLaunchAtLogin() {
        let shouldEnable = launchAtLoginButton.state == .on
        do {
            try LaunchAtLoginManager.shared.setEnabled(shouldEnable)
            updateState()
            PostHogSDK.shared.capture("settingChanged", properties: ["setting": "launchAtLogin", "enabled": String(shouldEnable)])
        } catch {
            updateState()
            showLaunchAtLoginError()
        }
    }

    @objc private func resetStats() {
        let alert = NSAlert()
        let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        alert.icon = appIcon
        alert.messageText = NSLocalizedString("stats.reset.title", comment: "")
        alert.informativeText = NSLocalizedString("stats.reset.message", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("stats.reset.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("stats.reset.cancel", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            StatsManager.shared.resetStats()
            PostHogSDK.shared.capture("statsReset")
        }
    }

    @objc private func exportData() {
        let savePanel = NSSavePanel()
        savePanel.allowedFileTypes = ["json"]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = makeExportFileName()
        savePanel.title = NSLocalizedString("export.savePanel.title", comment: "")
        savePanel.message = NSLocalizedString("export.savePanel.message", comment: "")
        savePanel.prompt = NSLocalizedString("export.savePanel.prompt", comment: "")

        guard let window = view.window else {
            if savePanel.runModal() == .OK, let url = savePanel.url {
                writeExport(to: url)
            }
            return
        }

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            self?.writeExport(to: url)
        }
    }

    private func makeExportFileName() -> String {
        let dateString = exportFileDateFormatter.string(from: Date())
        return "KeyStats-Export-\(dateString).json"
    }

    private func writeExport(to url: URL) {
        do {
            let data = try StatsManager.shared.exportStatsData()
            try data.write(to: url, options: .atomic)
        } catch {
            showExportError(error)
        }
    }

    private func showExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("export.error.title", comment: "")
        alert.informativeText = String(format: NSLocalizedString("export.error.message", comment: ""), error.localizedDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.ok", comment: ""))
        alert.runModal()
    }

    private func showLaunchAtLoginError() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("launchAtLogin.error.title", comment: "")
        alert.informativeText = NSLocalizedString("launchAtLogin.error.message", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.ok", comment: ""))
        alert.runModal()
    }
}
