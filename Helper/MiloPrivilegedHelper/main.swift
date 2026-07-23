import Foundation

private enum MiloPrivilegedHelperIdentity {
    static let machServiceName = "com.monomacaw.milo.helper"
}

private final class DenyAllConnectionDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        false
    }
}

private let connectionDelegate = DenyAllConnectionDelegate()
private let listener = NSXPCListener(machServiceName: MiloPrivilegedHelperIdentity.machServiceName)
listener.delegate = connectionDelegate
listener.resume()
RunLoop.current.run()
