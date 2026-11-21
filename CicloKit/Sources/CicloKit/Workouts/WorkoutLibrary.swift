/// Biblioteca de entrenamientos de referencia.
///
/// Son estructuras clásicas del entrenamiento por potencia (zonas de Coggan) y protocolos
/// estudiados (4×4, 30/15 de Rønnestad, 30/30 de Billat…), escritas aquí desde cero.
/// Las potencias van en fracción de tu FTP.
extension Workout {
    /// Nombre corto para celdas pequeñas (el plan de un vistazo); si no hay, el nombre.
    public var shortName: String { Self.shortNames[id] ?? name }

    static let shortNames = [
        "test-rampa": "Test rampa", "test-20": "Test 20'", "recuperacion-30": "Recup. 30'",
        "z2-60": "Z2 60'", "z2-90": "Z2 90'", "z2-120": "Z2 2 h", "tempo-3x10": "Tempo 3×10'",
        "ss-2x20": "SS 2×20'", "ss-3x15": "SS 3×15'", "umbral-3x12": "Umbral 3×12'",
        "over-unders": "Over-unders 3×(4×2'/1')", "vo2-4x4": "VO2 4×4'", "vo2-5x3": "VO2 5×3'",
        "vo2-30-15": "30/15 3×13", "vo2-30-30": "30/30 2×10", "anaerobico-8x1": "Anaer. 8×1'",
        "fuerza-5x5": "Fuerza 5×5' a 55 rpm", "fuerza-4x8": "Fuerza 4×8' a 60 rpm",
        "z2-fuerza-75": "Z2 75' con 6×3' de fuerza",
    ]

    public static let library: [Workout] = [
        // MARK: Tests
        Workout(
            id: "test-rampa", name: "Test de rampa", category: .test,
            summary: "Calienta 5' y después la potencia sube un 6 % de tu FTP cada minuto hasta que no puedas más. Para cuando no puedas mantener la cadencia y pulsa «Terminar». FTP estimado: 75 % de tu mejor minuto. Corto y fácil de repetir cada 4–6 semanas.",
            tagline: "+6 % cada minuto hasta no poder más",
            ftpTest: .ramp,
            steps: Workout.rampTestSteps()
        ),
        Workout(
            id: "test-20", name: "Test de FTP de 20 minutos", category: .test,
            summary: "El test clásico: calentamiento, 5' fuertes para vaciar la reserva anaeróbica, recuperación y 20' a tope y lo más constante posible (tramo libre: marca tú la potencia con las marchas). FTP estimado: 95 % de la media de esos 20'.",
            tagline: "20' a tope tras calentar y vaciar",
            ftpTest: .twentyMinutes,
            steps: [
                .ramp(seconds: 600, from: 0.45, to: 0.75),
                .intervals(repeats: 3, onSeconds: 60, onPower: 1.0, offSeconds: 60, offPower: 0.55),
                .steady(seconds: 180, power: 0.55),
                .freeRide(seconds: 300),
                .steady(seconds: 600, power: 0.50),
                .freeRide(seconds: 1_200),
                .ramp(seconds: 600, from: 0.60, to: 0.40),
            ]
        ),

        // MARK: Recuperación y resistencia
        Workout(
            id: "recuperacion-30", name: "Recuperación activa 30'", category: .recovery,
            summary: "Pedaleo muy suave para soltar piernas el día después de un entreno duro. Cadencia alta y cómoda.",
            tagline: "Soltar piernas al 52 %",
            steps: [.ramp(seconds: 300, from: 0.40, to: 0.50), .steady(seconds: 1_200, power: 0.52), .ramp(seconds: 300, from: 0.50, to: 0.40)]
        ),
        Workout(
            id: "z2-60", name: "Resistencia 60' (Z2)", category: .endurance,
            summary: "Base aeróbica: una hora en Z2, ritmo en el que podrías hablar. Es el grueso del entrenamiento en casi cualquier plan (entrenamiento polarizado).",
            tagline: "40' de base aeróbica al 68 %",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.65), .steady(seconds: 2_400, power: 0.68), .ramp(seconds: 600, from: 0.65, to: 0.45)]
        ),
        Workout(
            id: "z2-90", name: "Resistencia 90' (Z2)", category: .endurance,
            summary: "Salida larga de fondo en Z2. Mejora la capacidad aeróbica y el uso de grasas; la clave es no pasarse de intensidad.",
            tagline: "70' de fondo al 70 %",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.65), .steady(seconds: 4_200, power: 0.70), .ramp(seconds: 600, from: 0.65, to: 0.45)]
        ),

        // MARK: Tempo y sweet spot
        Workout(
            id: "tempo-3x10", name: "Tempo 3×10'", category: .tempo,
            summary: "Bloques en Z3, un ritmo «cómodamente duro». Resistencia muscular sin tanta fatiga como el umbral.",
            tagline: "3×10' al 83 %",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.70),
                    .intervals(repeats: 3, onSeconds: 600, onPower: 0.83, offSeconds: 300, offPower: 0.55),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        Workout(
            id: "ss-2x20", name: "Sweet spot 2×20'", category: .sweetSpot,
            summary: "El clásico para subir el FTP con poco tiempo: 2×20' al 88–94 % del FTP con 5' de descanso.",
            tagline: "2×20' al 90 %",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.75),
                    .intervals(repeats: 2, onSeconds: 1_200, onPower: 0.90, offSeconds: 300, offPower: 0.55),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        Workout(
            id: "ss-3x15", name: "Sweet spot 3×15'", category: .sweetSpot,
            summary: "Más volumen de sweet spot (45') en bloques algo más cortos y un punto más intensos.",
            tagline: "3×15' al 92 %",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.75),
                    .intervals(repeats: 3, onSeconds: 900, onPower: 0.92, offSeconds: 300, offPower: 0.55),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),

        // MARK: Umbral
        Workout(
            id: "umbral-3x12", name: "Umbral 3×12'", category: .threshold,
            summary: "Bloques justo en tu FTP (95–100 %). Entrenan aguantar el ritmo de una subida larga o una contrarreloj.",
            tagline: "3×12' al 98 %",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.75),
                    .intervals(repeats: 3, onSeconds: 720, onPower: 0.98, offSeconds: 360, offPower: 0.55),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        Workout(
            id: "over-unders", name: "Over-unders 3×(4×2'/1')", category: .threshold,
            summary: "Alternar por debajo (95 %) y por encima (108 %) del umbral: enseña a recuperar a ritmo alto tras un cambio de ritmo.",
            tagline: "3 series de 4×(2' al 95 % + 1' al 108 %)",
            steps: Workout.repeatedSets(
                warmup: [.ramp(seconds: 600, from: 0.45, to: 0.75)],
                set: [.intervals(repeats: 4, onSeconds: 120, onPower: 0.95, offSeconds: 60, offPower: 1.08),
                      .steady(seconds: 300, power: 0.55)],
                count: 3)
        ),

        // MARK: VO2max
        Workout(
            id: "vo2-4x4", name: "VO2max 4×4'", category: .vo2max,
            summary: "Inspirado en el 4×4 noruego: 4' al 110–115 % del FTP con 3' suaves. Uno de los métodos con más estudios para mejorar el VO2max.",
            tagline: "4×4' al 112 % con 3' suaves",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.75), .steady(seconds: 180, power: 0.55),
                    .intervals(repeats: 4, onSeconds: 240, onPower: 1.12, offSeconds: 180, offPower: 0.50),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        Workout(
            id: "vo2-5x3", name: "VO2max 5×3'", category: .vo2max,
            summary: "Algo más cortos y más intensos que el 4×4 (118 %). Mantén cadencia alta (90+).",
            tagline: "5×3' al 118 % con 3' suaves",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.75), .steady(seconds: 180, power: 0.55),
                    .intervals(repeats: 5, onSeconds: 180, onPower: 1.18, offSeconds: 180, offPower: 0.50),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        Workout(
            id: "vo2-30-15", name: "30/15 (Rønnestad) 3×13", category: .vo2max,
            summary: "3 series de 13×(30'' fuertes + 15'' suaves) con 3' entre series. En estudios de Rønnestad dio más tiempo cerca del VO2max que los intervalos largos.",
            tagline: "3 series de 13×(30'' al 120 % / 15'')",
            steps: Workout.repeatedSets(
                warmup: [.ramp(seconds: 600, from: 0.45, to: 0.75), .steady(seconds: 180, power: 0.55)],
                set: [.intervals(repeats: 13, onSeconds: 30, onPower: 1.20, offSeconds: 15, offPower: 0.50),
                      .steady(seconds: 180, power: 0.50)],
                count: 3)
        ),
        Workout(
            id: "vo2-30-30", name: "30/30 (Billat) 2×10", category: .vo2max,
            summary: "2 series de 10×(30'' al 120 % + 30'' suaves). Intervalos cortos para acumular minutos a intensidad de VO2max.",
            tagline: "2 series de 10×(30'' al 120 % / 30'')",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.75), .steady(seconds: 180, power: 0.55),
                    .intervals(repeats: 10, onSeconds: 30, onPower: 1.20, offSeconds: 30, offPower: 0.50),
                    .steady(seconds: 300, power: 0.50),
                    .intervals(repeats: 10, onSeconds: 30, onPower: 1.20, offSeconds: 30, offPower: 0.50),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),

        // MARK: Anaeróbico
        Workout(
            id: "anaerobico-8x1", name: "Anaeróbico 8×1'", category: .anaerobic,
            summary: "8×1' al 130 % con 2' de recuperación. Capacidad anaeróbica: ataques, repechos y cambios de ritmo.",
            tagline: "8×1' al 130 % con 2' suaves",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.75), .steady(seconds: 180, power: 0.55),
                    .intervals(repeats: 8, onSeconds: 60, onPower: 1.30, offSeconds: 120, offPower: 0.50),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        // MARK: Fuerza (cadencia baja)
        Workout(
            id: "fuerza-5x5", name: "Fuerza 5×5' a 55 rpm", category: .strength,
            summary: "Fuerza específica en la bici: 5' al 85 % del FTP con cadencia baja (55 rpm), como subir sentado con un desarrollo duro. Espalda quieta y empuje redondo; si te molestan las rodillas, sube a 65 rpm. 3' suaves a cadencia alta entre bloques.",
            tagline: "5×5' al 85 % a 55 rpm",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.70), .steady(seconds: 180, power: 0.55),
                    .lowCadence(repeats: 5, onSeconds: 300, onPower: 0.85, rpm: 55, offSeconds: 180, offPower: 0.55),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        Workout(
            id: "fuerza-4x8", name: "Fuerza 4×8' a 60 rpm", category: .strength,
            summary: "Bloques más largos de fuerza-resistencia al 88 % con 60 rpm: la base para las subidas largas y para ir cómodo con el monoplato en las rampas. 4' suaves entre bloques.",
            tagline: "4×8' al 88 % a 60 rpm",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.70), .steady(seconds: 180, power: 0.55),
                    .lowCadence(repeats: 4, onSeconds: 480, onPower: 0.88, rpm: 60, offSeconds: 240, offPower: 0.55),
                    .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        Workout(
            id: "z2-fuerza-75", name: "Z2 75' con 6×3' de fuerza", category: .strength,
            summary: "Rodaje en Z2 con 6 bloques cortos de 3' a 50 rpm al 80 %. Buen día intermedio: suma fuerza sin el cansancio de unos intervalos duros.",
            tagline: "Z2 con 6×3' a 50 rpm",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.65), .steady(seconds: 600, power: 0.68),
                    .lowCadence(repeats: 6, onSeconds: 180, onPower: 0.80, rpm: 50, offSeconds: 240, offPower: 0.68),
                    .steady(seconds: 300, power: 0.65), .ramp(seconds: 600, from: 0.60, to: 0.40)]
        ),
        Workout(
            id: "z2-120", name: "Resistencia 2 h (Z2)", category: .endurance,
            summary: "La salida larga de invierno en el rodillo: 1 h 40' en Z2. Mejora el fondo para las salidas largas de primavera. Bebe y come como en una salida de verdad.",
            tagline: "1 h 40' de fondo al 70 %",
            steps: [.ramp(seconds: 600, from: 0.45, to: 0.65), .steady(seconds: 6_000, power: 0.70), .ramp(seconds: 600, from: 0.65, to: 0.45)]
        ),
    ]

    /// Rampa: 5' de calentamiento, 2' suaves y escalones de 1' que suben un 6 % del FTP
    /// (del 50 % al 224 %: nadie llega al final, se para cuando no se puede más).
    static func rampTestSteps() -> [WorkoutStep] {
        var steps: [WorkoutStep] = [.ramp(seconds: 300, from: 0.40, to: 0.55), .steady(seconds: 120, power: 0.45)]
        for i in 0..<30 {
            steps.append(.steady(seconds: 60, power: 0.50 + 0.06 * Double(i)))
        }
        return steps
    }

    /// Calentamiento + `count` veces la serie + vuelta a la calma de 10'.
    static func repeatedSets(warmup: [WorkoutStep], set: [WorkoutStep], count: Int) -> [WorkoutStep] {
        var steps = warmup
        for _ in 0..<count { steps.append(contentsOf: set) }
        steps.append(.ramp(seconds: 600, from: 0.60, to: 0.40))
        return steps
    }
}
