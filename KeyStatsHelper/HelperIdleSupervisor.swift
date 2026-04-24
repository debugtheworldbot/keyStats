import Foundation

final class HelperIdleSupervisor {
    private let idleTimeout: TimeInterval = 30
    private var timer: DispatchSourceTimer?
    private var hasActiveConnection = false
    private let queue = DispatchQueue(label: "com.keystats.app.helper.idle")

    init() {
        scheduleIdleExit()
    }

    func connectionDidOpen() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.hasActiveConnection = true
            self.cancelIdleExit()
        }
    }

    func noteActivity() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.hasActiveConnection {
                self.cancelIdleExit()
            } else {
                self.scheduleIdleExit()
            }
        }
    }

    func connectionDidClose() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.hasActiveConnection = false
            self.scheduleIdleExit()
        }
    }

    private func scheduleIdleExit() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + idleTimeout)
        t.setEventHandler {
            NSLog("[KeyStatsHelper] idle timeout, exiting")
            exit(0)
        }
        t.resume()
        timer = t
    }

    private func cancelIdleExit() {
        timer?.cancel()
        timer = nil
    }
}
