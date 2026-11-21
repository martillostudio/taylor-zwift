import CicloKit
import Charts
import SwiftUI

/// «Tu forma»: forma, cansancio y frescura de hoy (intervals.icu) y cómo sube la forma con el plan.
struct FitnessCard: View {
    @Environment(IntervalsService.self) private var intervals
    @State private var selected: Date?

    var body: some View {
        if intervals.isConnected, !intervals.fitness.isEmpty {
            M3Card(style: .filled, padding: Space.xl) {
                VStack(alignment: .leading, spacing: Space.l) {
                    M3SectionTitle(title: "Tu forma",
                                   subtitle: "De intervals.icu: el rodillo por potencia y las salidas por pulso. Lo de después de hoy es la previsión si sigues el plan.")
                    if let today = intervals.fitness.day(on: Date()) {
                        let state = FormState(freshness: today.freshness)
                        HStack(alignment: .top, spacing: Space.l) {
                            M3Stat(title: "Forma", value: whole(today.fitness), size: .headlineMedium,
                                   caption: "media de 6 semanas")
                            M3Stat(title: "Cansancio", value: whole(today.fatigue), size: .headlineMedium,
                                   caption: "media de 1 semana")
                            M3Stat(title: "Frescura", value: signed(today.freshness), size: .headlineMedium,
                                   caption: state.name, captionColor: M3.onSurface)
                        }
                        Label(state.advice, systemImage: icon(state))
                            .font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurface)
                    }
                    chart
                    if let line = projectionText {
                        Text(line).font(M3.font(.bodyMedium)).foregroundStyle(M3.onSurfaceVariant)
                    }
                }
            }
        }
    }

    // MARK: Gráfica

    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }
    private var past: [FitnessDay] { intervals.fitness.filter { $0.date <= todayStart } }
    private var future: [FitnessDay] { intervals.fitness.filter { $0.date >= todayStart } }

    private var chart: some View {
        Chart {
            ForEach(past) { d in
                LineMark(x: .value("Día", d.date, unit: .day), y: .value("Forma", d.fitness),
                         series: .value("Tramo", "real"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(future) { d in
                LineMark(x: .value("Día", d.date, unit: .day), y: .value("Forma", d.fitness),
                         series: .value("Tramo", "previsión"))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            RuleMark(x: .value("Hoy", todayStart, unit: .day))
                .foregroundStyle(M3.outline)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .leading) {
                    Text("Hoy").font(M3.font(.labelSmall)).foregroundStyle(M3.onSurfaceVariant)
                }
            if let d = selectedDay {
                RuleMark(x: .value("Día", d.date, unit: .day))
                    .foregroundStyle(M3.outlineVariant)
                PointMark(x: .value("Día", d.date, unit: .day), y: .value("Forma", d.fitness))
                    .symbolSize(70)
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(d)
                    }
            }
        }
        .foregroundStyle(M3.primary)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(M3.outlineVariant.opacity(0.6))
                AxisValueLabel().foregroundStyle(M3.onSurfaceVariant)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisTick().foregroundStyle(M3.outlineVariant)
                AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(M3.onSurfaceVariant)
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: 180)
        .accessibilityLabel("Forma día a día: real hasta hoy y prevista con el plan")
    }

    private var selectedDay: FitnessDay? {
        guard let selected else { return nil }
        let day = Calendar.current.startOfDay(for: selected)
        return intervals.fitness.first { $0.date == day }
    }

    private func tooltip(_ d: FitnessDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(d.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                 + (d.date > todayStart ? " · previsión" : ""))
                .font(M3.font(.labelMedium)).foregroundStyle(M3.onSurfaceVariant)
            Text("Forma **\(whole(d.fitness))** · Cansancio \(whole(d.fatigue)) · Frescura \(signed(d.freshness))")
                .font(M3.font(.bodySmall, numeric: true)).foregroundStyle(M3.onSurface)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(M3.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(M3.outlineVariant))
    }

    // MARK: Textos

    /// «Con el plan, tu forma pasa de 19 a 27 (máximo el 4-feb).»
    private var projectionText: String? {
        guard let now = past.last, let peak = future.max(by: { $0.fitness < $1.fitness }),
              future.count > 7, peak.fitness > now.fitness + 0.5 else { return nil }
        let gain = Int(((peak.fitness / max(now.fitness, 1) - 1) * 100).rounded())
        return "Con el plan, tu forma pasa de \(whole(now.fitness)) a \(whole(peak.fitness)) (+\(gain) %), con el máximo hacia el \(peak.date.formatted(.dateTime.day().month(.wide))). Las salidas largas del fin de semana fuera del plan suman más."
    }

    private func whole(_ x: Double) -> String { "\(Int(x.rounded()))" }
    private func signed(_ x: Double) -> String {
        let n = Int(x.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    private func icon(_ s: FormState) -> String {
        switch s {
        case .transition: "arrow.down.right"
        case .fresh: "bolt.fill"
        case .neutral: "equal.circle"
        case .optimal: "chart.line.uptrend.xyaxis"
        case .highRisk: "exclamationmark.triangle.fill"
        }
    }
}
