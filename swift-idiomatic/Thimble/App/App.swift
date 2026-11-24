import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let client = BlueskyClient()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if TEST
        ts_test_start()
        #endif
        window = UIWindow(windowScene: windowScene)
        if client.session == nil { showLogin() } else { showMain() }
        window?.makeKeyAndVisible()
    }

    private func showLogin() {
        window?.rootViewController = LoginViewController(client: client) { [weak self] in self?.showMain() }
    }

    private func showMain() {
        let home = FeedViewController(client: client, title: "Home", source: TimelineSource(client: client))
        home.navigationItem.rightBarButtonItem = UIBarButtonItem(systemImage: "square.and.pencil") { [weak home] in
            home?.compose(replyingTo: nil)
        }
        let you = FeedViewController(client: client, title: "You", source: AuthorFeedSource(client: client, actor: client.did ?? ""))
        you.navigationItem.rightBarButtonItem = UIBarButtonItem(systemImage: "rectangle.portrait.and.arrow.right") { [weak self] in
            self?.client.adopt(nil)
            self?.showLogin()
        }
        let tabs = UITabBarController()
        tabs.viewControllers = [
            Self.tab(home, title: "Home", image: "house"),
            Self.tab(SearchViewController(client: client), title: "Search", image: "magnifyingglass"),
            Self.tab(FeedViewController(client: client, title: "Alerts", source: NotificationsSource(client: client)), title: "Alerts", image: "bell"),
            Self.tab(FeedViewController(client: client, title: "Chats", source: ConversationsSource(client: client)), title: "Chats", image: "bubble.left.and.bubble.right"),
            Self.tab(you, title: "You", image: "person"),
        ]
        window?.rootViewController = tabs
    }

    private static func tab(_ controller: UIViewController, title: String, image: String) -> UIViewController {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: image), tag: 0)
        return navigation
    }
}

final class LoginViewController: UIViewController {
    private let client: BlueskyClient
    private let onSignedIn: () -> Void
    private let handleField = UITextField(placeholder: "Handle")
    private let passwordField = UITextField(placeholder: "App password", secure: true)
    private let errorLabel = UILabel(style: .footnote, color: .systemRed)
    private var oauthFlow: OAuthFlow?

    init(client: BlueskyClient, onSignedIn: @escaping () -> Void) {
        self.client = client
        self.onSignedIn = onSignedIn
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let titleLabel = UILabel(style: .largeTitle, lines: 1)
        titleLabel.text = "Thimble"
        let signIn = UIButton(title: "Sign in") { [weak self] in self?.signInWithPassword() }
        let browser = UIButton(title: "Sign in with browser") { [weak self] in self?.signInWithBrowser() }
        browser.isHidden = OAuthFlow.clientID == nil

        let stack = UIStackView(axis: .vertical, spacing: 14, arranged: [titleLabel, handleField, passwordField, signIn, browser, errorLabel])
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    private func signInWithPassword() {
        errorLabel.text = ""
        Task {
            do {
                try await client.signIn(identifier: handleField.text ?? "", password: passwordField.text ?? "")
                onSignedIn()
            } catch {
                errorLabel.text = (error as? APIError)?.errorDescription ?? "Sign-in failed"
            }
        }
    }

    private func signInWithBrowser() {
        errorLabel.text = ""
        guard let handle = handleField.text, !handle.isEmpty else {
            errorLabel.text = "Enter your handle first"
            return
        }
        guard let window = view.window else { return }
        let flow = OAuthFlow(client: client, anchor: window)
        oauthFlow = flow
        Task {
            do {
                try await flow.signIn(handle: handle)
                onSignedIn()
            } catch {
                errorLabel.text = error.localizedDescription
            }
            oauthFlow = nil
        }
    }
}
