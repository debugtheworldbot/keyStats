import SwiftUI

/// KPS/CPS 详情弹窗视图
struct KPSDetailView: View {
    @State private var currentKPS: Int = 0
    @State private var currentCPS: Int = 0
    @State private var peakKPS: Int = 0
    @State private var peakCPS: Int = 0

    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            // KPS 区域
            rateSection(
                peakTitle: NSLocalizedString("kpsDetail.peakKPS", comment: ""),
                peak: peakKPS,
                currentTitle: NSLocalizedString("kpsDetail.currentKPS", comment: ""),
                current: currentKPS
            )

            Divider()

            // CPS 区域
            rateSection(
                peakTitle: NSLocalizedString("kpsDetail.peakCPS", comment: ""),
                peak: peakCPS,
                currentTitle: NSLocalizedString("kpsDetail.currentCPS", comment: ""),
                current: currentCPS
            )
        }
        .padding(16)
        .frame(width: 260)
        .onReceive(timer) { _ in
            refreshData()
        }
        .onAppear {
            refreshData()
        }
    }

    private func rateSection(peakTitle: String, peak: Int, currentTitle: String, current: Int) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peakTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(peak)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(currentTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(current)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.default, value: current)
            }
        }
    }

    private func refreshData() {
        let snapshot = StatsManager.shared.currentRatesSnapshot()
        currentKPS = snapshot.currentKPS
        currentCPS = snapshot.currentCPS
        peakKPS = snapshot.peakKPS
        peakCPS = snapshot.peakCPS
    }
}
