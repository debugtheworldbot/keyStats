import Foundation

final class HelperIdleSupervisor {
    private let idleTimeout: TimeInterval = 30
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.keystats.app.helper.idle")

    func noteActivity() { schedule() }
    func connectionDidClose() { schedule() }

    private func schedule() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.idleTimeout)
            t.setEventHandler {
                NSLog("[KeyStatsHelper] idle timeout, exiting")
                exit(0)
            }
            t.resume()
            self.timer = t
        }
    }
}
