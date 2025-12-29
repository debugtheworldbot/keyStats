import Cocoa

class MainWindowViewController: NSViewController {
    
    private let authorURL = URL(string: "https://github.com/debugtheworldbot")
    
    override func loadView() {
        let mainView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        mainView.wantsLayer = true
        self.view = mainView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        let titleLabel = makeLabel(text: "KeyStats", size: 22, weight: .bold)
        let versionLabel = makeLabel(text: versionText(), size: 12, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        
        let authorLabel = makeLabel(text: NSLocalizedString("about.author", comment: ""), size: 12, weight: .regular)
        authorLabel.textColor = .secondaryLabelColor
        
        let linkButton = NSButton(title: "github.com/debugtheworldbot", target: self, action: #selector(openAuthorLink))
        linkButton.isBordered = false
        linkButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        linkButton.contentTintColor = .linkColor
        
        let stack = NSStackView(views: [titleLabel, versionLabel, authorLabel, linkButton])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    
    private func makeLabel(text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.isSelectable = false
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        return label
    }
    
    private func versionText() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return String(format: NSLocalizedString("about.version", comment: ""), version, build)
    }
    
    @objc private func openAuthorLink() {
        guard let url = authorURL else { return }
        NSWorkspace.shared.open(url)
    }
}
