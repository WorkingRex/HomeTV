import Combine
import Foundation
import Network

struct AndroidTVDevice: Identifiable, Hashable {
    let name: String
    let type: String
    let domain: String

    var id: String { "\(name).\(type).\(domain)" }
}

@MainActor
final class TVDiscovery: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case ready
        case failed(String)
    }

    @Published private(set) var devices: [AndroidTVDevice] = []
    @Published private(set) var state: State = .idle

    private var browser: NWBrowser?

    func start() {
        browser?.cancel()
        devices = []
        state = .searching

        let browser = NWBrowser(
            for: .bonjour(type: "_androidtvremote2._tcp", domain: "local."),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in
                guard let self else { return }
                switch browserState {
                case .ready:
                    self.state = .ready
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    if self.state == .searching {
                        self.state = .idle
                    }
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results
                .compactMap { Self.device(from: $0.endpoint) }
                .sorted { $0.name < $1.name }
            Task { @MainActor in
                self?.devices = devices
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        if state == .searching {
            state = .idle
        }
    }

    nonisolated static func device(from endpoint: NWEndpoint) -> AndroidTVDevice? {
        guard case let .service(name, type, domain, _) = endpoint else {
            return nil
        }
        return AndroidTVDevice(name: name, type: type, domain: domain)
    }

    deinit {
        browser?.cancel()
    }
}