import Cocoa

class SettingsViewController: NSViewController, NSTextFieldDelegate {

    private var appIconView: NSImageView!
    private var showKeyPressesButton: NSButton!
    private var showMouseClicksButton: NSButton!
    private var launchAtLoginButton: NSButton!
    private var resetButton: NSButton!
    private var showThresholdsButton: NSButton!
    private var thresholdStack: NSStackView!
    private var keyPressThresholdField: NSTextField!
    private var keyPressThresholdStepper: NSStepper!
    private var clickThresholdField: NSTextField!
    private var clickThresholdStepper: NSStepper!

    private let thresholdMinimum = 0
    private let thresholdMaximum = 1_000_000
    private let thresholdStep = 100.0

    private lazy var thresholdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: thresholdMinimum)
        formatter.maximum = NSNumber(value: thresholdMaximum)
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        let mainView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
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

        launchAtLoginButton = NSButton(checkboxWithTitle: NSLocalizedString("button.launchAtLogin", comment: ""),
                                       target: self,
                                       action: #selector(toggleLaunchAtLogin))

        showThresholdsButton = NSButton(checkboxWithTitle: NSLocalizedString("setting.notificationsEnabled", comment: ""),
                                        target: self,
                                        action: #selector(toggleShowThresholds))

        let optionsStack = NSStackView(views: [showKeyPressesButton, showMouseClicksButton, launchAtLoginButton, showThresholdsButton])
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
        
        let contentStack = NSStackView(views: [optionsStack, thresholdStack, resetButton])
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
        launchAtLoginButton.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        let notificationsEnabled = StatsManager.shared.notificationsEnabled
        showThresholdsButton.state = notificationsEnabled ? .on : .off
        thresholdStack.isHidden = !notificationsEnabled
        updateThresholdUI()
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
        thresholdFieldEdited(field)
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

    @objc private func toggleLaunchAtLogin() {
        let shouldEnable = launchAtLoginButton.state == .on
        do {
            try LaunchAtLoginManager.shared.setEnabled(shouldEnable)
            updateState()
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
        }
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
