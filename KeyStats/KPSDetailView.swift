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
                title: NSLocalizedString("kpsDetail.kps", comment: ""),
                current: currentKPS,
                peakTitle: NSLocalizedString("kpsDetail.peak", comment: ""),
                peak: peakKPS
            )

            Divider()

            // CPS 区域
            rateSection(
                title: NSLocalizedString("kpsDetail.cps", comment: ""),
                current: currentCPS,
                peakTitle: NSLocalizedString("kpsDetail.peak", comment: ""),
                peak: peakCPS
            )
        }
        .padding(16)
        .frame(width: 200)
        .onReceive(timer) { _ in
            refreshData()
        }
        .onAppear {
            refreshData()
        }
    }

    private func rateSection(title: String, current: Int, peakTitle: String, peak: Int) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(current)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.default, value: current)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(peakTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(peak)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
    }

    private func refreshData() {
        let manager = StatsManager.shared
        currentKPS = manager.getCurrentKPS()
        currentCPS = manager.getCurrentCPS()
        peakKPS = Int(manager.currentStats.peakKPS)
        peakCPS = Int(manager.currentStats.peakCPS)
    }
}
