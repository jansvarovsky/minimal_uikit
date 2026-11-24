import PhotosUI
import UIKit

final class ComposeViewController: UIViewController {
    private let client: BlueskyClient
    private let parentPost: Post?
    private let onPosted: () -> Void
    private let textView = UITextView()
    private let descriptionField = UITextField(placeholder: "Image description")
    private var image: UIImage?

    init(client: BlueskyClient, parent: Post?, onPosted: @escaping () -> Void) {
        self.client = client
        parentPost = parent
        self.onPosted = onPosted
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = parentPost == nil ? "New post" : "Reply"
        textView.font = .preferredFont(forTextStyle: .body)
        textView.accessibilityLabel = "Post text"
        descriptionField.isHidden = true

        let photoButton = UIButton(title: "Add photo") { [weak self] in self?.pickPhoto() }
        let stack = UIStackView(axis: .vertical, spacing: 8, arranged: [textView, descriptionField, photoButton])
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemImage: "xmark") { [weak self] in self?.dismiss(animated: true) }
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemImage: "paperplane") { [weak self] in self?.submit() }
        textView.becomeFirstResponder()
    }

    private func pickPhoto() {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    fileprivate func attachImage(_ image: UIImage) {
        self.image = image
        descriptionField.isHidden = false
    }

    #if TEST
    @objc(attach:) func attach(_ image: UIImage) { attachImage(image) }
    #endif

    private func submit() {
        guard !textView.text.isEmpty else { return }
        Task {
            var embed: ImagesEmbed?
            if let image {
                guard let data = image.preparingThumbnail(of: CGSize(width: 1600, height: 1600))?.jpegData(compressionQuality: 0.75),
                      let blob = try? await client.uploadImage(data)
                else { return showAlert("Upload failed") }
                embed = ImagesEmbed(images: [.init(image: blob, alt: descriptionField.text ?? "")])
            }
            let reply = parentPost.map { ReplyReference(root: $0.record.reply?.root ?? $0.ref, parent: $0.ref) }
            do {
                try await client.publish(NewPost(text: textView.text, reply: reply, embed: embed))
                dismiss(animated: true)
                onPosted()
            } catch {
                showAlert("Could not post", message: error.localizedDescription)
            }
        }
    }
}

extension ComposeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        results.first?.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async { self?.attachImage(image) }
        }
    }
}
