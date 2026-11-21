import CicloKit
import Charts
import SwiftUI

// MARK: - Propuestas del entrenador

/// Cambios del plan que propone la app (sesión saltada, cansancio, intensidad por tipo).
/// Nada cambia hasta que pulsas «Aceptar»; «Ahora no» la quita para siempre.
struct ProposalsCard: View {
    @Environment(RideController.self) private var ride

    var body: some View {
        let proposals = ride.planProposals
        if !proposals.isEmpty {
            Card(style: .outlined) {
                VStack(alignment: .leading, spacing: Space.m) {
                    Label("Propuestas para tu plan", systemImage: "wand.and.stars")
                        .font(Theme.font(.titleSmall)).foregroundStyle(Theme.accent)
                    ForEach(proposals) { p in
                        VStack(alignment: .leading, spacing: Space.s) {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: icon(p.change)).foregroundStyle(Color.secondary)
                                    .accessibilityHidden(true)
                                Text(p.title).font(Theme.font(.bodyLarge).weight(.semibold))
                            }
                            Text(p.detail).font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Aceptar", systemImage: "checkmark") { ride.accept(p) }
                                    .buttonStyle(.borderedProminent)
                                Button("Ahora no") { ride.dismiss(p) }
                                    .buttonStyle(.bordered)
                                if ride.planPushedStart != nil, !isIntensity(p.change) {
                                    Text("Se actualiza también en intervals.icu y Garmin.")
                                        .font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
                                }
                            }
                        }
                        if p.id != proposals.last?.id { Divider().overlay(Theme.separator) }
                    }
                }
            }
        }
    }

    private func icon(_ c: PlanProposal.Change) -> String {
        switch c {
        case .move: "calendar.badge.clock"
        case .swap: "arrow.triangle.2.circlepath"
        case .intensity: "dial.medium"
        }
    }

    private func isIntensity(_ c: PlanProposal.Change) -> Bool {
        if case .intensity = c { return true }
        return false
    }
}

// MARK: - ¿Qué toca hoy?

/// Semáforo del día: apretar, rodaje controlado, suave o descanso, y por qué.
struct TodayCard: View {
    @Environment(RideController.self) private var ride
    @Environment(IntervalsService.self) private var intervals

    var body: some View {
        let advice = self.advice
        let style = DayCallStyle(advice.call)
        Card(style: .filled, padding: Space.xl) {
            HStack(alignment: .top, spacing: Space.l) {
                Image(systemName: style.icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(style.color, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("HOY · \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())")
                        .font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
                    Text(advice.headline).font(Theme.font(.headlineSmall).weight(.semibold))
                    ForEach(advice.reasons, id: \.self) { r in
                        Label(r, systemImage: "chevron.right")
                            .labelStyle(ReasonLabelStyle())
                            .font(Theme.font(.bodyMedium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !intervals.isConnected {
                        Text("Conecta intervals.icu en Historial para tener en cuenta tu cansancio.")
                            .font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
                    }
                    if let next = nextSession, next.session.id != todaySession?.id || advice.call == .rest {
                        Text("Siguiente: \(next.session.workout?.name ?? "salida en exterior"), el \(next.date.formatted(.dateTime.weekday(.wide).day()))")
                            .font(Theme.font(.bodySmall)).foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let w = nextSession?.session.workout {
                    let isToday = nextSession?.session.id == todaySession?.id
                    NavigationLink {
                        WorkoutDetailView(workout: w)
                            .onAppear {
                                // Se carga solo, salvo que estés en plena actividad con otra cosa.
                                if !ride.isRunning, ride.workout?.id != w.id || ride.mode != .workout { ride.load(w) }
                            }
                    } label: {
                        Label(isToday && advice.call != .rest ? "Ir al entreno" : "Ver entreno", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var today: Date { Date() }

    /// La sesión del plan que cae hoy.
    private var todaySession: PlanSession? {
        guard let week = ride.currentPlanWeek else { return nil }
        let weekStart = ride.plan.startOfWeek(week.number, start: ride.planStart)
        let offset = Calendar.current.dateComponents([.day], from: weekStart,
                                                     to: Calendar.current.startOfDay(for: today)).day ?? -1
        return week.sessions.first { $0.weekdayOffset == offset }
    }

    /// La próxima sesión pendiente del plan (la de hoy si aún no está hecha) y su día.
    private var nextSession: (session: PlanSession, date: Date)? {
        guard let week = ride.currentPlanWeek,
              let s = ride.plan.nextSession(in: week, statuses: ride.planStatus(week)) else { return nil }
        return (s, ride.date(of: s, in: week))
    }

    private var advice: TodayAdvice {
        let session = todaySession
        let done = session.flatMap { s in ride.currentPlanWeek.map { ride.planStatus($0)[s.id]?.isDone ?? false } } ?? false
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: today))!
        let yesterdayLoad = intervals.recent
            .filter { cal.isDate($0.start, inSameDayAs: yesterday) }
            .reduce(0) { $0 + ($1.load ?? 0) }
        let todayLoad = intervals.recent
            .filter { cal.isDateInToday($0.start) }
            .reduce(0) { $0 + ($1.load ?? 0) }
        return Coach.today(freshness: intervals.fitness.day(on: today)?.freshness,
                           rampPerWeek: intervals.fitness.rampPerWeek(on: today),
                           session: session, doneToday: done, yesterdayLoad: yesterdayLoad,
                           todayLoad: done ? 0 : todayLoad)
    }
}

private struct DayCallStyle {
    let color: Color
    let icon: String

    init(_ call: DayCall) {
        switch call {
        case .push: color = .orange; icon = "flame.fill"
        case .steady: color = .green; icon = "heart.fill"
        case .easy: color = .yellow; icon = "tortoise.fill"
        case .rest: color = .indigo; icon = "bed.double.fill"
        }
    }
}

/// Frase con una flechita delante, alineada arriba.
private struct ReasonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 9, weight: .bold)).foregroundStyle(Color.secondary)
            configuration.title
        }
    }
}

// MARK: - Hacia dónde vamos

/// Las 16 semanas en una línea: en qué fase estás, próxima descarga, próximo test y forma prevista.
struct RoadAheadCard: View {
    @Environment(RideController.self) private var ride
    @Environment(IntervalsService.self) private var intervals

    var body: some View {
        let plan = ride.plan
        let week = plan.weekNumber(on: Date(), start: ride.planStart)
        Card(style: .filled, padding: Space.xl) {
            VStack(alignment: .leading, spacing: Space.l) {
                SectionTitle(title: "Hacia dónde vamos", subtitle: subtitle(week))
                PhaseTimeline(phases: plan.phases, weeks: plan.weeks.count, current: week)
                VStack(alignment: .leading, spacing: Space.m) {
                    if let w = week, let current = plan.weeks.first(where: { $0.number == w }) {
                        fact("scope", "Esta semana", "\(current.block): \(current.focus.lowercased())")
                    }
                    if let r = plan.nextRecoveryWeek(from: (week ?? 0) + (isRecoveryNow(week) ? 1 : 0)) {
                        fact("bed.double", "Próxima descarga",
                             "semana \(r.number), desde el \(dateText(plan.startOfWeek(r.number, start: ride.planStart)))")
                    }
                    if let t = plan.nextTest(from: (week ?? 1) + 1) {
                        let day = Calendar.current.date(byAdding: .day, value: t.session.weekdayOffset,
                                                        to: plan.startOfWeek(t.week.number, start: ride.planStart))!
                        fact("gauge.with.needle", "Próximo test de FTP", "semana \(t.week.number), el \(dateText(day))")
                    }
                    if let (now, end) = projection {
                        fact("chart.line.uptrend.xyaxis", "Forma al terminar",
                             "de \(Int(now.rounded())) hoy a unos \(Int(end.rounded())) si sigues el plan")
                    }
                }
            }
        }
    }

    private func subtitle(_ week: Int?) -> String {
        guard let week else { return "El plan empieza el \(dateText(ride.planStart))." }
        return "Semana \(week) de \(ride.plan.weeks.count) · quedan \(ride.plan.weeks.count - week)"
    }

    private func isRecoveryNow(_ week: Int?) -> Bool {
        week.flatMap { w in ride.plan.weeks.first { $0.number == w }?.isRecovery } ?? false
    }

    private var projection: (Double, Double)? {
        let end = ride.plan.startOfWeek(ride.plan.weeks.count + 1, start: ride.planStart)
        guard let now = intervals.fitness.day(on: Date()), let last = intervals.fitness.day(on: end),
              last.date > now.date else { return nil }
        return (now.fitness, last.fitness)
    }

    private func fact(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
                Text(text).font(Theme.font(.bodyMedium)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dateText(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Las fases del plan como una barra partida; la semana actual, marcada.
private struct PhaseTimeline: View {
    let phases: [PlanPhase]
    let weeks: Int
    let current: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let unit = (geo.size.width - CGFloat(phases.count - 1) * 2) / CGFloat(max(weeks, 1))
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 2) {
                        ForEach(phases) { p in
                            let isNow = current.map { p.weeks.contains($0) } ?? false
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(p).opacity(isNow ? 1 : (isPast(p) ? 0.35 : 0.6)))
                                .frame(width: unit * CGFloat(p.weeks.count))
                                .help("\(p.name): semanas \(p.weeks.lowerBound)–\(p.weeks.upperBound)")
                        }
                    }
                    .frame(height: 14)
                    if let current {
                        let gaps = CGFloat(phases.filter { $0.weeks.upperBound < current }.count) * 2
                        Capsule()
                            .fill(Color.primary)
                            .frame(width: 3, height: 22)
                            .offset(x: unit * (CGFloat(current) - 0.5) + gaps - 1.5, y: -4)
                            .accessibilityLabel("Semana \(current)")
                    }
                }
            }
            .frame(height: 18)
            HStack(spacing: Space.m) {
                legend("Base", .blue)
                legend("Construcción", .orange)
                legend("Descarga", .green)
                legend("Final", .purple)
            }
            .font(Theme.font(.labelSmall))
            .foregroundStyle(Color.secondary)
        }
    }

    private func isPast(_ p: PlanPhase) -> Bool { current.map { p.weeks.upperBound < $0 } ?? false }

    private func color(_ p: PlanPhase) -> Color {
        if p.isRecovery { return .green }
        if p.name.hasPrefix("Base") { return .blue }
        if p.name.hasPrefix("Construcción") { return .orange }
        return .purple
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c.opacity(0.7)).frame(width: 10, height: 8)
            Text(t)
        }
    }
}

// MARK: - Carga semanal

/// TSS hecho frente al previsto, semana a semana, y a qué ritmo sube la forma.
struct WeeklyLoadCard: View {
    @Environment(RideController.self) private var ride
    @Environment(IntervalsService.self) private var intervals
    @Environment(ActivityStore.self) private var store
    @State private var selected: Int?

    var body: some View {
        let current = ride.plan.weekNumber(on: Date(), start: ride.planStart) ?? 0
        let data = ride.plan.weeklyLoads(start: ride.planStart, loads: loads, upTo: ride.plan.weeks.count)
        Card(style: .filled, padding: Space.xl) {
            VStack(alignment: .leading, spacing: Space.l) {
                SectionTitle(title: "Carga semanal", subtitle: "TSS hecho (color) frente al previsto (gris)")
                Chart {
                    ForEach(data) { w in
                        // yStart/yEnd: las dos barras se superponen en vez de apilarse.
                        BarMark(x: .value("Semana", w.week), yStart: .value("TSS", 0), yEnd: .value("TSS", w.planned),
                                width: .fixed(16))
                            .foregroundStyle(Color.secondary.opacity(0.22))
                            .cornerRadius(3)
                        if w.week <= current {
                            BarMark(x: .value("Semana", w.week), yStart: .value("TSS", 0), yEnd: .value("TSS", w.done),
                                    width: .fixed(9))
                                .foregroundStyle(w.week == current ? Theme.accent.opacity(0.7) : Theme.accent)
                                .cornerRadius(3)
                        }
                    }
                    if let s = selected, let w = data.first(where: { $0.week == s }) {
                        RuleMark(x: .value("Semana", s))
                            .foregroundStyle(Theme.separator)
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(w, current: current)
                            }
                    }
                }
                .chartXScale(domain: 0.5...(Double(ride.plan.weeks.count) + 0.5))
                .chartXAxis {
                    AxisMarks(values: Array(stride(from: 1, through: ride.plan.weeks.count, by: 1))) { v in
                        AxisValueLabel { if let n = v.as(Int.self), n % 2 == 1 || n == current { Text("\(n)") } }
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Theme.separator.opacity(0.6))
                        AxisValueLabel().foregroundStyle(Color.secondary)
                    }
                }
                .chartXSelection(value: $selected)
                .frame(height: 170)
                .accessibilityLabel("Carga por semana: hecha frente a prevista")

                if let w = data.first(where: { $0.week == current }) {
                    Text("Esta semana: \(Int(w.done.rounded())) de \(Int(w.planned.rounded())) TSS previstos.")
                        .font(Theme.font(.bodyMedium))
                }
                if let r = intervals.fitness.rampPerWeek(on: Date()) {
                    let pace = RampPace(perWeek: r)
                    Label("Forma \(r >= 0 ? "+" : "")\(Int(r.rounded())) en 7 días. \(pace.text)",
                          systemImage: pace == .aggressive ? "exclamationmark.triangle.fill" : "speedometer")
                        .font(Theme.font(.bodyMedium))
                        .foregroundStyle(pace == .aggressive ? Color.orange : Color.primary)
                }
            }
        }
    }

    /// Carga de cada salida: la de intervals.icu (incluye lo que sale a la calle); sin
    /// intervals, la de los entrenos guardados aquí.
    private var loads: [(date: Date, load: Double)] {
        if intervals.isConnected, !intervals.recent.isEmpty {
            return intervals.recent.compactMap { a in a.load.map { (a.start, $0) } }
        }
        return store.activities.compactMap { a in a.tss.map { (a.start, Double($0)) } }
    }

    private func tooltip(_ w: WeekLoad, current: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Semana \(w.week)\(w.isRecovery ? " · descarga" : "")")
                .font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
            Text(w.week <= current ? "\(Int(w.done.rounded())) de \(Int(w.planned.rounded())) TSS"
                 : "\(Int(w.planned.rounded())) TSS previstos")
                .font(Theme.font(.bodySmall, numeric: true))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator))
    }
}

// MARK: - Mejora aeróbica y FTP

/// FTP estimado con el tiempo, mejores marcas y eficiencia en Z2.
struct ImprovementCard: View {
    @Environment(RideController.self) private var ride
    @Environment(IntervalsService.self) private var intervals
    @Environment(ActivityStore.self) private var store

    var body: some View {
        Card(style: .filled, padding: Space.xl) {
            VStack(alignment: .leading, spacing: Space.l) {
                SectionTitle(title: "Mejora aeróbica y FTP",
                             subtitle: "Si el FTP sube y en Z2 sacas más vatios con el mismo pulso, la base está mejorando.")
                HStack(alignment: .top, spacing: Space.l) {
                    Stat(title: "FTP", value: "\(ride.ftp)", unit: "W", size: .headlineMedium,
                         caption: "\(String(format: "%.1f", Double(ride.ftp) / ride.weightKg).replacingOccurrences(of: ".", with: ",")) W/kg")
                    Stat(title: "Mejor 5'", value: best(300).map { "\($0)" } ?? "—", unit: "W", size: .headlineMedium,
                         caption: "últimas 6 semanas")
                    Stat(title: "Mejor 20'", value: best(1_200).map { "\($0)" } ?? "—", unit: "W", size: .headlineMedium,
                         caption: "últimas 6 semanas")
                }
                if Set(eftp.map { Calendar.current.startOfDay(for: $0.date) }).count >= 2 { eftpChart }
                efficiency
            }
        }
    }

    // MARK: FTP

    private var eftp: [(date: Date, watts: Double)] {
        intervals.recent.compactMap { a in a.estimatedFTP.map { (a.start, $0) } }.sorted { $0.date < $1.date }
    }

    private var eftpChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FTP ESTIMADO (intervals.icu)").font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
            Chart {
                ForEach(eftp, id: \.date) { p in
                    LineMark(x: .value("Día", p.date, unit: .day), y: .value("W", p.watts))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Theme.accent)
                }
                RuleMark(y: .value("Tu FTP", ride.ftp))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("tu FTP \(ride.ftp) W").font(Theme.font(.labelSmall)).foregroundStyle(Color.secondary)
                    }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.separator.opacity(0.6))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Color.secondary)
                }
            }
            .frame(height: 110)
        }
    }

    private func best(_ seconds: Int) -> Int? {
        let since = Date().addingTimeInterval(-42 * 86_400)
        return store.activities.filter { $0.start >= since }
            .compactMap { $0.powerHistory.bestAverage(seconds: seconds) }
            .max().map { Int($0.rounded()) }
    }

    // MARK: Eficiencia

    @ViewBuilder
    private var efficiency: some View {
        let points = store.activities.compactMap { a in a.efficiencyFactor.map { (date: a.start, ef: $0) } }
            .sorted { $0.date < $1.date }
        VStack(alignment: .leading, spacing: 4) {
            Text("EFICIENCIA EN Z2 (vatios por latido)").font(Theme.font(.labelMedium)).foregroundStyle(Color.secondary)
            if points.count >= 2 {
                Chart(points, id: \.date) { p in
                    LineMark(x: .value("Día", p.date, unit: .day), y: .value("W/ppm", p.ef))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Día", p.date, unit: .day), y: .value("W/ppm", p.ef))
                        .symbolSize(40)
                }
                .foregroundStyle(Color.green)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Theme.separator.opacity(0.6))
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Theme.separator.opacity(0.6))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(d, format: .number.precision(.fractionLength(2))) } }
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: 110)
                let change = (points.last!.ef / points.first!.ef - 1) * 100
                Text(change >= 0 ? "+\(Int(change.rounded())) % desde el primer rodaje: sacas más vatios con el mismo pulso."
                     : "\(Int(change.rounded())) %: normal si estás cansado o hace calor; mira la tendencia de varias semanas.")
                    .font(Theme.font(.bodyMedium))
            } else {
                Text(points.isEmpty
                     ? "Aparecerá con tus rodajes en Z2 de 30' o más con el pulsómetro puesto."
                     : "Tienes 1 rodaje que cuenta (\(String(format: "%.2f", points[0].ef)) W/ppm). Con unos cuantos más verás la tendencia.")
                    .font(Theme.font(.bodyMedium)).foregroundStyle(Color.secondary)
            }
        }
    }
}
