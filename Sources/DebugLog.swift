import Foundation

private let isDebug = ProcessInfo.processInfo.environment["EB_DEBUG"] != nil

func debugLog(_ text: @autoclosure () -> String) {
    guard isDebug else { return }
    print(text())
    fflush(stdout)
}
