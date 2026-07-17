import Cocoa

final class SyncSettingsWindowController: NSWindowController {
    static let shared = SyncSettingsWindowController()

    private init() {
        let controller = SyncSettingsViewController()
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = NSLocalizedString("sync.window.title", comment: "")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 640))
        window.minSize = NSSize(width: 520, height: 560)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppDelegate.trackPageView("sync_settings")
    }
}

private final class SyncSettingsViewController: NSViewController {
    private let coordinator = SyncCoordinator.shared
    private var observer: NSObjectProtocol?
    private var contentStack: NSStackView!
    private var statusIndicator: NSTextField!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var primaryActions: NSStackView!
    private var pairActions: NSStackView!
    private var configuredActions: NSStackView!
    private var devicesStack: NSStackView!
    private var pairingCodeLabel: NSTextField!
    private var createGroupButton: NSButton!
    private var forgetLocalButton: NSButton!
    private var checkPairingButton: NSButton!
    private var manualSyncButton: NSButton!
    private var pairCodeField: NSTextField!
    private var refreshTimer: Timer?
    private var helpPopover: NSPopover?
    private var isRunningOperation = false

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        refreshTimer?.invalidate()
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        observer = NotificationCenter.default.addObserver(
            forName: .syncStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatusOnly()
        }
        refresh()
    }

    private func setupUI() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view.addSubview(scrollView)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        document.addSubview(contentStack)

        let title = NSTextField(labelWithString: NSLocalizedString("sync.title", comment: ""))
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        let helpButton = makeHelpButton()
        let titleRow = NSStackView(views: [title, helpButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        contentStack.addArrangedSubview(titleRow)

        let privacy = wrappingLabel("sync.privacy.message", color: .secondaryLabelColor)
        contentStack.addArrangedSubview(privacy)
        privacy.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let statusCard = makeCard()
        let statusStack = verticalStack(spacing: 6)
        statusIndicator = NSTextField(labelWithString: "●")
        statusIndicator.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statusIndicator.setAccessibilityElement(false)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let statusRow = NSStackView(views: [statusIndicator, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        detailLabel = wrappingLabel(nil, color: .secondaryLabelColor)
        statusStack.addArrangedSubview(statusRow)
        statusStack.addArrangedSubview(detailLabel)
        pin(statusStack, in: statusCard)
        contentStack.addArrangedSubview(statusCard)

        primaryActions = verticalStack(spacing: 10)
        createGroupButton = button("sync.action.create", action: #selector(createGroup))
        let beginPairButton = button("sync.action.pairNewDevice", action: #selector(beginPairing))
        let recoverButton = button("sync.action.recover", action: #selector(recover))
        forgetLocalButton = button("sync.action.forgetLocal", action: #selector(forgetLocalSync))
        let primaryRow = NSStackView(views: [createGroupButton, beginPairButton, recoverButton])
        primaryRow.orientation = .horizontal
        primaryRow.spacing = 10
        primaryActions.addArrangedSubview(primaryRow)
        primaryActions.addArrangedSubview(forgetLocalButton)
        contentStack.addArrangedSubview(primaryActions)

        pairActions = verticalStack(spacing: 8)
        pairingCodeLabel = NSTextField(labelWithString: "")
        pairingCodeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        pairingCodeLabel.alignment = .center
        checkPairingButton = button("sync.action.checkPairing", action: #selector(checkPairing))
        let codeRow = NSStackView(views: [pairingCodeLabel, checkPairingButton])
        codeRow.orientation = .horizontal
        codeRow.alignment = .centerY
        codeRow.spacing = 16
        pairActions.addArrangedSubview(wrappingLabel("sync.pair.codeHelp", color: .secondaryLabelColor))
        pairActions.addArrangedSubview(codeRow)
        contentStack.addArrangedSubview(pairActions)
        pairActions.isHidden = true

        configuredActions = verticalStack(spacing: 12)
        let syncRow = NSStackView()
        syncRow.orientation = .horizontal
        syncRow.spacing = 10
        manualSyncButton = button("sync.action.syncNow", action: #selector(syncNow))
        syncRow.addArrangedSubview(manualSyncButton)
        syncRow.addArrangedSubview(button("sync.action.showRecoveryCode", action: #selector(showStoredRecoveryCode)))
        syncRow.addArrangedSubview(button("sync.action.leave", action: #selector(leaveSync)))
        configuredActions.addArrangedSubview(syncRow)

        let pairTitle = NSTextField(labelWithString: NSLocalizedString("sync.pair.enterCode", comment: ""))
        pairTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pairCodeField = NSTextField()
        pairCodeField.placeholderString = "000000"
        pairCodeField.maximumNumberOfLines = 1
        pairCodeField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let joinButton = button("sync.action.join", action: #selector(joinPairing))
        let joinRow = NSStackView(views: [pairTitle, pairCodeField, joinButton])
        joinRow.orientation = .horizontal
        joinRow.alignment = .centerY
        joinRow.spacing = 10
        configuredActions.addArrangedSubview(joinRow)

        let devicesTitle = NSTextField(labelWithString: NSLocalizedString("sync.devices.title", comment: ""))
        devicesTitle.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        configuredActions.addArrangedSubview(devicesTitle)
        devicesStack = verticalStack(spacing: 8)
        devicesStack.setContentHuggingPriority(.required, for: .vertical)
        devicesStack.setContentCompressionResistancePriority(.required, for: .vertical)
        configuredActions.addArrangedSubview(devicesStack)

        let deviceSectionSpacer = NSView()
        deviceSectionSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        deviceSectionSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configuredActions.addArrangedSubview(deviceSectionSpacer)

        let deleteButton = button("sync.action.deleteVault", action: #selector(deleteVault))
        deleteButton.contentTintColor = .systemRed
        configuredActions.addArrangedSubview(deleteButton)
        contentStack.addArrangedSubview(configuredActions)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            statusCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            primaryActions.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            pairActions.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            configuredActions.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            devicesStack.widthAnchor.constraint(equalTo: configuredActions.widthAnchor)
        ])
    }

    private func refresh() {
        let configured = coordinator.state.isConfigured
        primaryActions.isHidden = configured && !coordinator.state.needsRepair
        configuredActions.isHidden = !configured || coordinator.state.needsRepair
        createGroupButton.isHidden = coordinator.state.needsRepair
        forgetLocalButton.isHidden = !coordinator.state.needsRepair
        refreshStatusOnly()
        rebuildDevices()
    }

    private func refreshStatusOnly() {
        if !coordinator.isServiceConfigured {
            statusIndicator.textColor = .systemGray
            statusLabel.stringValue = NSLocalizedString("sync.status.serviceNotConfigured", comment: "")
            detailLabel.stringValue = NSLocalizedString("sync.status.serviceNotConfigured.detail", comment: "")
            primaryActions.isHidden = false
            primaryActions.arrangedSubviews.forEach { $0.isHidden = true }
            configuredActions.isHidden = true
            return
        }
        primaryActions.arrangedSubviews.forEach { $0.isHidden = false }
        let state = coordinator.state
        forgetLocalButton.isHidden = !state.needsRepair
        if state.needsRepair {
            statusIndicator.textColor = .systemRed
            statusLabel.stringValue = NSLocalizedString("sync.status.needsRepair", comment: "")
            detailLabel.stringValue = NSLocalizedString("sync.status.needsRepair.detail", comment: "")
        } else if coordinator.isSyncing {
            statusIndicator.textColor = .systemYellow
            statusLabel.stringValue = NSLocalizedString("sync.status.syncing", comment: "")
            if let progress = coordinator.syncProgress, progress.totalDays > 0 {
                detailLabel.stringValue = String(
                    format: NSLocalizedString("sync.status.syncing.progress", comment: ""),
                    progress.completedDays,
                    progress.totalDays
                )
            } else {
                detailLabel.stringValue = NSLocalizedString("sync.status.syncing.detail", comment: "")
            }
        } else if coordinator.lastError != nil &&
                    (coordinator.canRetryBootstrap || state.activeDeviceCount >= 2) {
            statusIndicator.textColor = .systemRed
            statusLabel.stringValue = NSLocalizedString("sync.status.failed", comment: "")
            detailLabel.stringValue = coordinator.lastError?.localizedDescription ?? ""
        } else if !state.isConfigured {
            statusIndicator.textColor = .systemGray
            statusLabel.stringValue = NSLocalizedString("sync.status.off", comment: "")
            detailLabel.stringValue = NSLocalizedString("sync.status.off.detail", comment: "")
        } else if state.activeDeviceCount < 2 {
            statusIndicator.textColor = .systemGray
            statusLabel.stringValue = NSLocalizedString("sync.status.singleDevice", comment: "")
            detailLabel.stringValue = NSLocalizedString("sync.status.singleDevice.detail", comment: "")
        } else {
            statusLabel.stringValue = NSLocalizedString("sync.status.on", comment: "")
            if let last = state.lastSuccessfulSyncAt {
                statusIndicator.textColor = .systemGreen
                detailLabel.stringValue = String(format: NSLocalizedString("sync.status.lastSync", comment: ""), Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))
            } else {
                statusIndicator.textColor = .systemGray
                detailLabel.stringValue = NSLocalizedString("sync.status.notYetSynced", comment: "")
            }
        }

        manualSyncButton?.isEnabled = !isRunningOperation &&
            (coordinator.canRetryBootstrap || coordinator.availability == .available) &&
            !coordinator.isSyncing
        if coordinator.canRetryBootstrap {
            manualSyncButton?.title = NSLocalizedString("sync.action.retrySetup", comment: "")
        } else if case .coolingDown(let date) = coordinator.availability {
            let seconds = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
            manualSyncButton?.title = String(format: NSLocalizedString("sync.action.cooldown", comment: ""), seconds / 60, seconds % 60)
        } else {
            manualSyncButton?.title = NSLocalizedString("sync.action.syncNow", comment: "")
        }
    }

    private func rebuildDevices() {
        guard devicesStack != nil else { return }
        for view in devicesStack.arrangedSubviews {
            devicesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let state = coordinator.state
        for device in state.devices where !device.isRevoked {
            let title = device.isCurrent
                ? "\(device.displayName) · \(NSLocalizedString("sync.device.thisDevice", comment: ""))"
                : device.displayName
            let label = NSTextField(labelWithString: title)
            label.lineBreakMode = .byTruncatingMiddle
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            var views: [NSView] = [label, spacer]
            if !device.isCurrent {
                let revoke = DeviceActionButton(title: NSLocalizedString("sync.action.revoke", comment: ""), target: self, action: #selector(revokeDevice(_:)))
                revoke.deviceId = device.deviceId
                revoke.bezelStyle = .rounded
                views.append(revoke)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            devicesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: devicesStack.widthAnchor).isActive = true
        }
        let missing = max(0, state.activeDeviceCount - state.devices.filter { !$0.isRevoked }.count)
        if missing > 0 {
            let label = NSTextField(labelWithString: String(format: NSLocalizedString("sync.device.unknownCount", comment: ""), missing))
            label.textColor = .secondaryLabelColor
            devicesStack.addArrangedSubview(label)
        }
    }

    // MARK: - Actions

    @objc private func createGroup() {
        run { [weak self] in
            guard let self else { return }
            let code = try coordinator.prepareSyncGroup()
            guard showRecoveryCode(code, allowsCancel: true) else {
                try coordinator.cancelPreparedSyncGroup()
                return
            }
            try await coordinator.confirmAndCreateSyncGroup()
        }
    }

    @objc private func beginPairing() {
        run { [weak self] in
            guard let self else { return }
            let session = try await coordinator.beginPairing()
            pairingCodeLabel.stringValue = session.code
            pairActions.isHidden = false
        }
    }

    @objc private func checkPairing() {
        run { [weak self] in
            guard let self else { return }
            let preview = try await coordinator.fetchPairingApproval()
            guard confirmSafetyCode(preview.safetyCode) else { return }
            try await coordinator.confirmPairing(safetyCodeConfirmed: true)
            pairActions.isHidden = true
        }
    }

    @objc private func joinPairing() {
        let code = pairCodeField.stringValue.filter(\.isNumber)
        guard code.count == 6 else {
            showError(SyncCoordinatorError.invalidPairingCode)
            return
        }
        run { [weak self] in
            guard let self else { return }
            let preview = try await coordinator.joinPairing(code: code)
            guard confirmSafetyCode(preview.safetyCode) else { return }
            try await coordinator.approvePairing(safetyCodeConfirmed: true)
            pairCodeField.stringValue = ""
        }
    }

    @objc private func recover() {
        guard let code = promptForSecret(
            title: NSLocalizedString("sync.recover.title", comment: ""),
            message: NSLocalizedString("sync.recover.message", comment: "")
        ) else { return }
        run { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.recover(recoveryCode: code)
            } catch SyncTransportError.maximumDevices(let vaultId, let devices) {
                try await completeCapacityLimitedRecovery(vaultId: vaultId, devices: devices)
            }
        }
    }

    @objc private func showStoredRecoveryCode() {
        do {
            let needsConfirmation = coordinator.hasUnconfirmedCreate
            let confirmed = showRecoveryCode(
                try coordinator.recoveryCodeForDisplay(),
                allowsCancel: needsConfirmation
            )
            guard needsConfirmation else { return }
            guard confirmed else {
                try coordinator.cancelPreparedSyncGroup()
                refresh()
                return
            }
            run { [weak self] in try await self?.coordinator.confirmAndCreateSyncGroup() }
        } catch {
            showError(error)
        }
    }

    @objc private func syncNow() {
        run { [weak self] in
            guard let self else { return }
            do {
                if coordinator.hasUnconfirmedCreate {
                    guard showRecoveryCode(
                        try coordinator.recoveryCodeForDisplay(),
                        allowsCancel: true
                    ) else {
                        try coordinator.cancelPreparedSyncGroup()
                        return
                    }
                    try await coordinator.confirmAndCreateSyncGroup()
                } else if coordinator.canRetryBootstrap {
                    try await coordinator.retryBootstrap()
                } else {
                    try await coordinator.manualSync()
                }
            } catch SyncTransportError.maximumDevices(let vaultId, let devices) {
                try await completeCapacityLimitedRecovery(vaultId: vaultId, devices: devices)
            }
        }
    }

    @MainActor
    private func completeCapacityLimitedRecovery(
        vaultId: String?,
        devices: [SyncEncryptedDeviceV1]
    ) async throws {
        guard coordinator.hasPendingRecovery else {
            throw SyncTransportError.maximumDevices(vaultId: vaultId, devices: devices)
        }
        let options = try coordinator.recoveryReplacementOptions(
            vaultId: vaultId,
            devices: devices
        )
        guard let vaultId else { throw SyncTransportError.invalidResponse }
        guard let selected = promptForRecoveryReplacement(options) else {
            try coordinator.cancelPendingRecovery()
            return
        }
        try await coordinator.retryRecovery(replacing: selected, vaultId: vaultId)
    }

    @objc private func revokeDevice(_ sender: DeviceActionButton) {
        guard let deviceId = sender.deviceId,
              confirmDestructive(titleKey: "sync.revoke.confirm.title", messageKey: "sync.revoke.confirm.message") else { return }
        run { [weak self] in try await self?.coordinator.revokeDevice(deviceId: deviceId) }
    }

    @objc private func leaveSync() {
        guard confirmDestructive(titleKey: "sync.leave.confirm.title", messageKey: "sync.leave.confirm.message") else { return }
        run { [weak self] in try await self?.coordinator.leaveSync() }
    }

    @objc private func forgetLocalSync() {
        guard confirmDestructive(
            titleKey: "sync.forgetLocal.confirm.title",
            messageKey: "sync.forgetLocal.confirm.message"
        ) else { return }
        do {
            try coordinator.forgetLocalSyncAfterRepair()
            refresh()
        } catch {
            showError(error)
        }
    }

    @objc private func deleteVault() {
        guard confirmDestructive(titleKey: "sync.delete.confirm.title", messageKey: "sync.delete.confirm.message") else { return }
        run { [weak self] in try await self?.coordinator.deleteVault() }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isRunningOperation else { return }
        isRunningOperation = true
        setActionButtonsEnabled(false)
        Task { @MainActor [weak self] in
            defer {
                self?.isRunningOperation = false
                self?.setActionButtonsEnabled(true)
                self?.refresh()
            }
            do {
                try await operation()
            } catch {
                self?.showError(error)
            }
        }
    }

    private func setActionButtonsEnabled(_ enabled: Bool) {
        func visit(_ view: NSView) {
            if let button = view as? NSButton { button.isEnabled = enabled }
            view.subviews.forEach(visit)
        }
        visit(view)
    }

    // MARK: - Alerts

    @discardableResult
    private func showRecoveryCode(_ code: String, allowsCancel: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("sync.recoveryCode.title", comment: "")
        alert.informativeText = NSLocalizedString("sync.recoveryCode.message", comment: "")
        let field = NSTextField(labelWithString: code)
        field.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold)
        field.isSelectable = true
        field.alignment = .center
        field.frame = NSRect(x: 0, y: 0, width: 390, height: 28)
        field.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(copyRecoveryCode(_:)))
        )
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("sync.recoveryCode.saved", comment: ""))
        if allowsCancel {
            alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
        }
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed {
            copyRecoveryCodeToPasteboard(code)
        }
        return confirmed
    }

    @objc private func copyRecoveryCode(_ sender: NSClickGestureRecognizer) {
        guard let field = sender.view as? NSTextField else { return }
        copyRecoveryCodeToPasteboard(field.stringValue)
    }

    private func copyRecoveryCodeToPasteboard(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func confirmSafetyCode(_ code: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("sync.safetyCode.title", comment: "")
        alert.informativeText = String(format: NSLocalizedString("sync.safetyCode.message", comment: ""), code)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("sync.safetyCode.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func promptForSecret(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("sync.action.recover", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func confirmDestructive(titleKey: String, messageKey: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(titleKey, comment: "")
        alert.informativeText = NSLocalizedString(messageKey, comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func promptForRecoveryReplacement(
        _ options: [SyncRecoveryReplacementOption]
    ) -> SyncRecoveryReplacementOption? {
        guard !options.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("sync.recover.replace.title", comment: "")
        alert.informativeText = NSLocalizedString("sync.recover.replace.message", comment: "")
        alert.alertStyle = .warning
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for option in options {
            let suffix = option.platform.isEmpty ? "" : " · \(option.platform)"
            popup.addItem(withTitle: option.displayName + suffix)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: NSLocalizedString("sync.recover.replace.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return options[popup.indexOfSelectedItem]
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func showSyncHelp(_ sender: NSButton) {
        if helpPopover?.isShown == true {
            helpPopover?.close()
            return
        }

        AppDelegate.trackClick("sync_help")
        let popover = helpPopover ?? makeHelpPopover()
        helpPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        AppDelegate.trackPageView("sync_help")
    }

    // MARK: - UI helpers

    private func makeHelpButton() -> NSButton {
        let description = NSLocalizedString("sync.help.button", comment: "")
        let button: NSButton
        if let image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: description) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button = NSButton(image: image.withSymbolConfiguration(configuration) ?? image, target: self, action: #selector(showSyncHelp(_:)))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
        } else {
            button = NSButton(title: "?", target: self, action: #selector(showSyncHelp(_:)))
            button.bezelStyle = .circular
        }
        button.toolTip = description
        button.setAccessibilityLabel(description)
        return button
    }

    private func makeHelpPopover() -> NSPopover {
        let contentSize = NSSize(width: 500, height: 520)
        let contentView = NSView()
        contentView.frame = NSRect(origin: .zero, size: contentSize)
        let stack = verticalStack(spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let title = NSTextField(labelWithString: NSLocalizedString("sync.help.title", comment: ""))
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(title)

        let instructions = wrappingLabel("sync.help.instructions", color: .labelColor)
        instructions.font = NSFont.systemFont(ofSize: 13)
        stack.addArrangedSubview(instructions)
        instructions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let dataTitle = NSTextField(labelWithString: NSLocalizedString("sync.help.dataTitle", comment: ""))
        dataTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(dataTitle)

        let includedData = wrappingLabel("sync.help.dataIncluded", color: .labelColor)
        includedData.font = NSFont.systemFont(ofSize: 12.5)
        stack.addArrangedSubview(includedData)
        includedData.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let excludedData = wrappingLabel("sync.help.dataExcluded", color: .secondaryLabelColor)
        excludedData.font = NSFont.systemFont(ofSize: 12.5)
        stack.addArrangedSubview(excludedData)
        excludedData.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let statusTitle = NSTextField(labelWithString: NSLocalizedString("sync.help.statusTitle", comment: ""))
        statusTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(statusTitle)
        stack.addArrangedSubview(statusLegendRow(color: .systemGreen, key: "sync.help.status.synced"))
        stack.addArrangedSubview(statusLegendRow(color: .systemGray, key: "sync.help.status.inactive"))
        stack.addArrangedSubview(statusLegendRow(color: .systemYellow, key: "sync.help.status.syncing"))
        stack.addArrangedSubview(statusLegendRow(color: .systemRed, key: "sync.help.status.failed"))

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])

        let controller = NSViewController()
        controller.view = contentView
        controller.preferredContentSize = contentSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = contentSize
        return popover
    }

    private func statusLegendRow(color: NSColor, key: String) -> NSView {
        let indicator = NSTextField(labelWithString: "●")
        indicator.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        indicator.textColor = color
        indicator.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: NSLocalizedString(key, comment: ""))
        let row = NSStackView(views: [indicator, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func makeCard() -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 12
        card.borderWidth = 0.5
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        return card
    }

    private func pin(_ content: NSView, in container: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
    }

    private func wrappingLabel(_ key: String?, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: key.map { NSLocalizedString($0, comment: "") } ?? "")
        label.textColor = color
        label.maximumNumberOfLines = 0
        return label
    }

    private func button(_ key: String, action: Selector) -> NSButton {
        let button = NSButton(title: NSLocalizedString(key, comment: ""), target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private final class DeviceActionButton: NSButton {
    var deviceId: String?
}
