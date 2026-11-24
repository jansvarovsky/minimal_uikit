import UIKit

extension UIView {
    func pinEdges(to guide: UILayoutGuide) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: guide.topAnchor),
            leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
    }

    func fill(with subview: UIView) {
        addSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.leadingAnchor.constraint(equalTo: leadingAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

extension UIStackView {
    convenience init(axis: NSLayoutConstraint.Axis, spacing: CGFloat, arranged: [UIView]) {
        self.init(arrangedSubviews: arranged)
        self.axis = axis
        self.spacing = spacing
    }
}

extension UILabel {
    convenience init(style: UIFont.TextStyle, color: UIColor = .label, lines: Int = 0) {
        self.init()
        font = .preferredFont(forTextStyle: style)
        textColor = color
        numberOfLines = lines
        adjustsFontForContentSizeCategory = true
    }
}

extension UITextField {
    convenience init(placeholder: String, secure: Bool = false) {
        self.init()
        self.placeholder = placeholder
        isSecureTextEntry = secure
        borderStyle = .roundedRect
        autocapitalizationType = .none
        autocorrectionType = .no
    }
}

extension UIButton {
    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(type: .system)
        setTitle(title, for: .normal)
        addAction(UIAction { _ in handler() }, for: .primaryActionTriggered)
    }
}

extension UIBarButtonItem {
    convenience init(systemImage: String, handler: @escaping () -> Void) {
        self.init(primaryAction: UIAction(image: UIImage(systemName: systemImage)) { _ in handler() })
    }
}

extension UIViewController {
    func showAlert(_ title: String, message: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Images

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

final class RemoteImageView: UIImageView {
    private var task: Task<Void, Never>?

    convenience init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat) {
        self.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = cornerRadius
        backgroundColor = .secondarySystemBackground
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
    }

    func load(_ address: String?) {
        task?.cancel()
        image = nil
        guard let address, let url = URL(string: address) else { return }
        task = Task { [weak self] in
            let loaded = await ImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            self?.image = loaded
        }
    }
}
