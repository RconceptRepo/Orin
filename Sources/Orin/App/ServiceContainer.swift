import Foundation

protocol Service {}

final class ServiceContainer {
    static let shared = ServiceContainer()

    private var services: [String: Any] = [:]

    private init() {}

    func register<T>(_ service: T, for type: T.Type) {
        services[String(describing: type)] = service
    }

    func resolve<T>(_ type: T.Type) -> T {
        let key = String(describing: type)
        guard let service = services[key] as? T else {
            fatalError("Service \(key) not registered.")
        }
        return service
    }
}
