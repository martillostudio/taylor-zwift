# Guía de construcción — taylor-zwift

> Fase 0 del proyecto. Este documento fija **qué** vamos a construir, **con qué**, **qué riesgos** hay y **en qué orden**. Se actualiza cuando cambie una decisión (ver «Registro de decisiones» al final).

## 1. Objetivo

App de entrenamiento indoor tipo MyWhoosh/Zwift, para uso propio (y quizá publicarla más adelante), que:

- funcione en **MacBook, iPad e iPhone**;
- controle el **Wahoo Kickr Core 2** (lectura de potencia/cadencia, modo SIM con pendiente, modo ERG);
- use los **Zwift Click V2** para subir y bajar marchas virtuales;
- sea **código abierto**.

Prioridad 1: **poder entrenar y usar los mandos**. Todo lo demás (mapas, avatares, Strava…) va después.

## 2. Decisiones técnicas

| Tema | Decisión | Por qué |
|---|---|---|
| Lenguaje / UI | **Swift 6 + SwiftUI** | Nativo de Apple; un solo código para Mac, iPad e iPhone. |
| Web / PWA | **Descartado** | Safari en iOS/iPadOS no soporta Web Bluetooth: no podríamos hablar con el rodillo desde iPhone/iPad. |
| Proyecto | **Una app multiplataforma** de Xcode (iOS + iPadOS + macOS nativo, no Catalyst) | Un target, una base de código. |
| Bluetooth | **CoreBluetooth** (framework de Apple) | Sin dependencias externas. |
| Arquitectura | App de Xcode + **paquete Swift local `CicloKit`** con la lógica | La lógica (protocolos, física, entrenos) no depende de la UI ni del Bluetooth real → se puede testear sin hardware. |
| Estado de la UI | `@Observable` (framework Observation) | Lo más simple y moderno en SwiftUI. |
| Versiones mínimas | **iOS/iPadOS 17 y macOS 14** | Necesarias para `@Observable`. Entorno de desarrollo: macOS 26.6, Xcode 26.3, Swift 6.4. |
| Exportar actividades | `garmin/fit-swift-sdk` (Fase 3) | SDK oficial de FIT. |
| Licencia | **GPL-3.0** (`LICENSE`) | Quien reutilice el código debe publicar el suyo; encaja con los proyectos de referencia. |

### Estructura de carpetas

```
taylor-zwift/
├── README.md
├── Makefile                 ← atajos: make test / build / run / logs
├── docs/                    ← esta guía y notas técnicas
├── App/
│   ├── project.yml          ← descripción del proyecto (XcodeGen)
│   ├── TaylorZwift.xcodeproj  ← generado desde project.yml (no editar a mano)
│   ├── TaylorZwift.entitlements
│   └── Sources/             ← SwiftUI: pantallas Rodillo, Mandos, Log
└── CicloKit/                ← paquete Swift
    ├── Package.swift
    ├── Sources/
    │   ├── CicloKit/        ← lógica pura, con tests
    │   │   ├── FTMS/        ← bytes ↔ structs del rodillo
    │   │   ├── ZwiftClick/  ← botones del Click V2
    │   │   └── (Physics/, Workouts/ en fases siguientes)
    │   └── CicloBluetooth/  ← capa CoreBluetooth (solo se prueba con hardware)
    └── Tests/CicloKitTests/
```

Regla de oro: **el código que traduce bytes y hace cálculos no toca CoreBluetooth**. Así Claude puede escribirlo y probarlo con tests automáticos, y tú solo pruebas en el rodillo la capa fina de conexión.

## 3. Requisitos de Apple (cosas que tienes que hacer tú)

1. **Xcode** actualizado (ya instalado ✅).
2. **Cuenta de Apple en Xcode** (Xcode → Settings → Accounts):
   - *Gratis*: puedes instalar en tu iPhone/iPad, pero la app **caduca a los 7 días** y hay que volver a instalarla desde Xcode. Suficiente para empezar.
   - *Apple Developer Program* (99 €/año): sin caducidad, TestFlight y App Store. Solo si un día quieres publicarla o te cansas de reinstalar.
3. **Permisos que configuraremos en el proyecto**:
   - `NSBluetoothAlwaysUsageDescription` (texto que explica por qué usamos Bluetooth).
   - En macOS, App Sandbox → **Bluetooth** activado.
   - (Más adelante, opcional) modo en segundo plano `bluetooth-central` en iOS para seguir conectado con la pantalla apagada.
4. **El simulador de iOS no tiene Bluetooth**: las pruebas con el rodillo se hacen en el **Mac (destino «My Mac»)** o en un iPhone/iPad real. El Mac es lo más rápido para iterar.

## 4. Protocolos (resumen; detalle en `docs/protocolos.md` cuando lo escribamos)

**Kickr Core 2 — FTMS** (servicio `0x1826`)
- `0x2AD2` Indoor Bike Data (notify): velocidad, cadencia, potencia.
- `0x2AD9` Control Point (write + indicate): `0x00` pedir control · `0x05` potencia objetivo (ERG) · `0x11` simulación (viento, pendiente en 0,01 %, Crr, CdA).
- `0x2ADA` Machine Status.

**Zwift Click V2** (servicio `0xFC82`)
- Handshake: escribir `RideOn` en la característica sync RX.
- Botones: mensaje con opcode `0x23`, protobuf con `ButtonMap`; **bit a 0 = pulsado**.
- Mando derecho (+, A, B, Y, Z) funciona libre. Según BikeControl, **el izquierdo está bloqueado para Zwift** (ver riesgos); el 19-nov funcionó.
- El izquierdo **reenvía los botones del derecho**: conectando solo el izquierdo se leen los dos mandos.
- Batería: opcode `0x19`, protobuf campo 2 = %.

Referencias (solo para leer, no copiar código): BikeControl (protocolo Click), Auuki (FTMS y física). Ver doc del proyecto «repos-y-protocolos».

## 5. Riesgos y cómo los atacamos

| Riesgo | Impacto | Qué haremos |
|---|---|---|
| **Mando izquierdo del Click V2 bloqueado** (deja de enviar botones a apps de terceros tras ~1 min) | **Requisito: tienen que funcionar los dos mandos** | Ver §5.1. Se mide en la prueba B antes de nada más. *19-nov: el izquierdo envió botones durante ~11 min sin cortes; falta la prueba de 30 min.* |
| **Una sola app controlando el rodillo** | Si Zwift/MyWhoosh/Wahoo están abiertos, no conectamos o no nos deja controlar | Cerrar esas apps al probar. La app mostrará un error claro si el control point rechaza `0x00`. |
| **Mandos emparejados con el rodillo** (Kickr Core 2 + Zwift) | El Click puede estar vinculado al rodillo y no anunciarse a nosotros | Comprobarlo en la prueba B (Fase 1). *19-nov: no pasa; los dos se anuncian y conectan con el Kickr también conectado.* |
| **Caducidad 7 días (cuenta gratuita)** | Molestia en iPhone/iPad | Iterar en el Mac; decidir cuenta de pago más adelante. |
| **Claude no puede ejecutar Xcode ni Bluetooth** | Bucle de prueba más lento | Lógica pura con tests; logs claros en pantalla para que copies y pegues lo que ves. |

### 5.1 Plan para que funcionen los dos mandos

Situación conocida (nov. 2026, según el issue #68 de BikeControl y su guía de problemas): el mando **derecho** funciona sin restricciones; el **izquierdo** deja de mandar pulsaciones a apps que no sean Zwift tras un minuto aproximadamente, salvo que Zwift lo «desbloquee» antes. Los resultados que cuenta la gente son irregulares y el mecanismo exacto no se conoce.

Estrategia en capas (de más a menos fiable):

1. **Reconexión automática del izquierdo.** La app detecta que el mando izquierdo ha dejado de responder y lo reconecta sola en segundo plano (es lo que hace BikeControl: «reiniciar cada minuto»). Objetivo: que no lo notes al pedalear. Riesgo: perder alguna pulsación durante la reconexión → lo mediremos.
2. **Desbloqueo previo con Zwift.** Antes de entrenar, abrir Zwift, conectar los Click 10–30 s y cerrarlo del todo. La app mostrará un aviso si detecta el mando bloqueado. Hay que comprobar si funciona **sin suscripción** de Zwift.
3. **Plan B de mapeo.** Si aun así el izquierdo falla, todas las funciones críticas (subir/bajar marcha) estarán también disponibles en el derecho, para que el entrenamiento no se pare nunca.

Qué **no** haremos: intentar romper el mecanismo de bloqueo/desafío de Zwift (nadie lo ha conseguido de forma fiable y entra en terreno de términos de uso).

Precauciones:
- **No actualizar el firmware de los Click V2** sin comprobarlo antes (BikeControl recomienda no hacerlo; la versión 1.2.0 de marzo de 2026 tiene resultados inciertos).
- El **KICKR Bridge** del Core 2 puede reenviar los Click V2, pero solo hacia Zwift; para otras apps solo reenvía pulsómetro. No es una vía para nosotros.

Observado el 19-nov: el **izquierdo reenvía los botones del derecho** (no al revés). Si el izquierdo se bloquea, hay que ver si también deja de reenviar; el derecho conectado directamente sigue dando sus propios botones.

## 6. Plan por fases

### Fase 0 — Guía (esta) ✅
Salida: este documento + decisiones pendientes resueltas (ver §7 y registro).

### Fase 1 — Pruebas de riesgo («spikes»)
Dos pantallas mínimas dentro de la app, sin diseño:

- **Prueba A — Rodillo**
  - [x] Escanea y lista dispositivos FTMS. *(19-nov: encuentra «KICKR CORE 7A53»)*
  - [x] Conecta al Kickr y muestra potencia, cadencia y velocidad en vivo.
  - [x] Pide control (`0x00`) y cambia la pendiente (`0x11`) con un slider: notas la resistencia. *(19-nov: OK, se nota)*
  - [x] Pone 150 W en ERG (`0x05`). *(19-nov: a 70 W se mantiene 67–73 W entre 48 y 55 rpm)*
- **Prueba B — Mandos**
  - [x] Escanea y encuentra **los dos** Click V2. *(19-nov)*
  - [x] Hace el handshake `RideOn` con cada uno.
  - [x] Muestra en pantalla qué botón pulsas y de qué mando. *(19-nov: el log dice por qué mando llega cada pulsación; ecos filtrados)*
  - [ ] Registra con hora cada pulsación y desconexión del izquierdo (¿se corta al minuto?). *(19-nov: ~11 min sin cortes, sin saber si Zwift lo había desbloqueado antes)*
  - [ ] Reconexión automática del izquierdo: ¿cuánto tarda? ¿se pierden pulsaciones?
  - [ ] Probar con y sin desbloqueo previo en Zwift; anotar si hace falta suscripción.

Criterio para pasar a Fase 2: A funciona y **los dos mandos son usables durante 30 min seguidos** en el Mac. Si algo falla, se corrige el plan aquí antes de seguir.

### Fase 2 — MVP para entrenar
Pestaña **«Rodar»** de la app TaylorZwift (19-nov: primera versión escrita, falta probarla en el rodillo).

- [x] Pantalla de rodaje: potencia, cadencia, velocidad, distancia, tiempo, media, trabajo, pendiente, marcha y perfil de la ruta.
- [x] Modo **SIM** con rutas sencillas incluidas (llano, ondulado, puerto 8 km al 6 %): la pendiente sale de la distancia recorrida, suavizada en 50 m y mandada como mucho 1 vez/s.
- [x] **Marchas virtuales** con desarrollos de bici real: ver abajo.
- [x] **Pulsómetro** Bluetooth estándar (servicio `0x180D`): pulso en vivo, medio y máximo; se conecta y reconecta solo.
- [x] **Vista 2D tipo Garmin/Wahoo**: pendiente con su color, adelanto de los próximos 2 km, perfil de la ruta coloreado por pendiente (lo recorrido en gris) y panel de subida tipo ClimbPro (lo que queda: km, metros y pendiente media; categoría).
- [x] Modo **ERG** con los mismos botones (±10 W).
- [x] **Reconexión automática** del rodillo y los mandos; al volver, el rodillo recupera el último modo. Botón «Conectar rodillo y mandos».
- [x] Primera prueba en el rodillo (19-nov): todo conecta y las marchas cambian la resistencia, pero la marcha más blanda era demasiado dura → desarrollos reales.
- [ ] Probar los desarrollos reales, el pulsómetro y la vista 2D.

**Cómo funcionan las marchas virtuales.** El rodillo tiene un desarrollo real fijo: la velocidad de su volante solo depende de la cadencia. Medido en el Kickr Core 2: **0,356 km/h por rpm** (relación ≈ 2,82 con rueda de 2,105 m, como un 50×18); la app lo va afinando sola. Una marcha de bici con relación *r* es *k = r / 2,82* veces más dura que el rodillo «a pelo». Para esa *k*, la velocidad «de carretera» es *k* veces la del volante y hay que pedir *k* veces la fuerza de pendiente y rodadura y *k³* la del aire:
`F' = k·m·g·(pendiente + Crr) + k³·½ρCdA·v²`. Eso se consigue mandando en el comando SIM `pendiente·k`, `Crr·k` y `CdA·k³`; el rodillo hace el resto con su física, sin bucles de control. El tope es *k* ≈ 1,71 (máximo de CdA de FTMS: 2,55 kg/m con 0,51 de base); la marcha más dura de carretera (50×11) es *k* = 1,61.

Desarrollos (`CicloKit/Ride/Drivetrain.swift`):
- **Carretera 2×12** (50/34 · 11-34): 24 marchas repartidas por igual (cada salto ≈ 6,8 %) entre 34×34 y 50×11, con el nombre de la combinación real más parecida. Un doble plato real tiene marchas repetidas; repartirlas es lo que hacen los cambios virtuales.
- **Gravel GRX 1×12** (40 · 10-51) y **SRAM XPLR 1×12** (40 · 10-44): las 12 marchas reales.
- Pendiente: SRAM 1×13 (falta confirmar el cassette) y los platos/piñones exactos de la Grizl.

*19-nov, primera prueba:* con las 24 marchas antiguas (0,5×–1,7× del rodillo) la marcha 1 equivalía a un 34×24 y el 3 % no se subía «de molinillo». Con el desarrollo real, la marcha 1 (34×34) pide al rodillo un 35 % de la pendiente (antes, un 50 %).

**Vista 2D.** Colores de pendiente de Garmin ClimbPro: verde 0–3 %, amarillo 3–6 %, naranja 6–9 %, rojo 9–12 %, rojo oscuro > 12 %; bajadas en azul. Subida = al menos 500 m, 3 % de media y longitud × pendiente ≥ 3.500 (criterio de Garmin); categoría por esa puntuación (4.ª > 8.000, 3.ª > 16.000, 2.ª > 32.000, 1.ª > 64.000, HC > 80.000). Adelanto de 2 km como Wahoo Summit. Código: `CicloKit/Ride/Climb.swift`, `App/Sources/GradeColors.swift`.

**Botones** (los mismos que «Taylor Mandos»): + (dcha) o Z, marcha más dura / +10 W; − (izq) o Y, más blanda / −10 W.

### Fase 2b — Entrenador (19-nov: primera versión escrita)
Prioridad del usuario: más un **entrenador** (FTP, VO2max, planes) que un simulador.

- [x] Perfil: FTP y peso (se guardan), W/kg y zonas de potencia de Coggan (Z1–Z7) en vatios.
- [x] Entrenos estructurados: pasos (constante, rampa, intervalos, libre) → tramos; objetivo en % del FTP mandado en **ERG**; tramos libres en SIM llano con marchas. IF y TSS previstos.
- [x] Biblioteca de referencia (`CicloKit/Workouts/WorkoutLibrary.swift`), escrita desde cero con estructuras clásicas: test de rampa, test de 20', recuperación, Z2 60'/90', tempo 3×10', sweet spot 2×20' y 3×15', umbral 3×12', over-unders, VO2max 4×4' (tipo noruego), 5×3', 30/15 (Rønnestad), 30/30 (Billat), anaeróbico 8×1'.
- [x] Tests de FTP: rampa (75 % del mejor minuto) y 20' (95 % de la media). Al terminar propone el FTP nuevo.
- [x] VO2max estimado con la ecuación del ACSM (10,8 · W/kg de la mejor potencia de 5' + 7). Aproximado.
- [x] Importar `.zwo` (formato de Zwift) para usar entrenos de otras fuentes.
- [x] Intensidad ±2 % con los Click durante un entreno.
- [ ] Probarlo en el rodillo.
- [x] Plan **«Invierno en el rodillo» (16 semanas)** (`CicloKit/Workouts/TrainingPlan.swift`): 3 sesiones/semana, 3+1 semanas de carga/descarga, polarizado (mucho Z2 + 2 días de calidad: fuerza a cadencia baja, sweet spot/umbral, VO2max), test de FTP en las semanas 1, 8 y 16; las últimas semanas, salida larga en exterior. Hecho a partir de las salidas de Garmin (mayo–nov 2026: ~2 salidas/semana, 4,8 h, 700 m por salida, pulso medio en Z3).
- [x] Entrenos de fuerza con **cadencia objetivo** (5×5' a 55 rpm, 4×8' a 60 rpm, Z2 con 6×3' a 50 rpm) y Z2 de 2 h.
- [x] Zonas de pulso por % de la FC máxima (las de Garmin) además de las de potencia.
- [x] Biblioteca en **tarjetas**: perfil por zonas, lema, reparto del tiempo por zonas, duración, TSS, zona principal, «TEST» y «rpm».
- [x] **Entreno libre** (modo «Libre» en «Rodar» y tarjeta en «Entrenar»): pendiente elegida por ti (deslizador, atajos 0/3/6/8/10 % o la cruceta ↑/↓ del mando izquierdo, en pasos de 0,5 %) y marchas virtuales; «Terminar» da el resumen (distancia, tiempo, medias, mejores 1'/5'/20', VO2max estimado).
- [x] Desarrollo por defecto: monoplato 1×12 (el de la Grizl; falta confirmar el cassette exacto). Se guarda el que elijas.
- [x] **Seguimiento del plan** (21-nov): cada entreno guardado cuenta para su sesión si es el mismo entreno y de esa semana (da igual el día) y dura al menos el 80 %; si no, «a medias». Estados: hecha, a medias, hoy, no hecha (no se recupera), próxima. Tarjeta «Hoy toca» con botón para ir al entreno; contador por semana; marcar a mano con clic derecho (salidas en exterior o entrenos hechos fuera).
- [x] **Botones del mando derecho** (21-nov): **A** empieza / pausa; **B** dos veces en 3 s termina y guarda (la primera pulsación avisa). Aviso flotante arriba.
- [ ] Analizar el histórico de Garmin Connect (ficheros `.fit`) para estimar FTP/VO2max y proponer el plan.
- [x] **Historial:** cada entreno de más de 1' se guarda al terminar (o al ponerlo a cero) como JSON (muestras a 1 Hz: potencia, cadencia, velocidad, distancia, pulso, altura virtual) y como `.fit` (codificador propio en `CicloKit/Activity/FITEncoder.swift`, con tests que releen el fichero y comprueban los CRC). Pestaña «Historial»: totales de semana y mes, tarjetas, detalle con gráficas, mejores marcas, tiempo por zonas, exportar `.fit`.
- [x] **Strava:** OAuth (WebAuthenticationSession, `taylorzwift://localhost`), subida del `.fit` a `/api/v3/uploads` (permiso `activity:write`) con `trainer=1`, seguimiento hasta que Strava la procesa, subida automática opcional. Hace falta crear una «app» en strava.com/settings/api con *Authorization Callback Domain* = `localhost`.
- [x] **Garmin Connect** (vía oficial): su API personal solo permite *descargar*, así que el botón «Subir a Garmin Connect» abre su página «Importar datos» y selecciona el `.fit` en el Finder para arrastrarlo (Safari a veces falla al importar: mejor Chrome o Edge).
- Nota (19-nov): **Strava exige suscripción para crear una app de la API**; sin ella la subida a Strava no se puede usar (queda como opción).
- [x] **intervals.icu** (21-nov): gratis, clave de API (Settings → Developer Settings), autenticación básica `API_KEY:<clave>`, `POST /api/v1/athlete/0/activities` con el `.fit` (no duplica: comprueba el hash). Subida automática al terminar; la clave va al llavero. intervals.icu puede traer también las salidas de Garmin Connect: junta rodillo y calle.
- [x] **Salidas en exterior en el plan** (21-nov): la app descarga de intervals.icu tus actividades (`GET /api/v1/athlete/0/activities`) al abrir «Entrenar» (como mucho cada 10', o con «Actualizar»). Las salidas en bici por la calle (`Ride`, `GravelRide`, `MountainBikeRide`, sin `trainer` y que no subimos nosotros) cuentan para las sesiones «Salida en exterior» de su semana: hecha con 1 h 30 min o más, si no «a medias». «Resistencia 2 h» en el rodillo también vale para esas sesiones. Si el eFTP de intervals.icu (`icu_rolling_ftp`) difiere 5 W o más del tuyo, «Tu perfil» propone usarlo.
- [x] **El plan en el calendario de intervals.icu** (21-nov): botón «Mandar a intervals.icu» en el plan. Cada sesión va como entreno con su `.zwo` (`ZwoEncoder`, con cadencia objetivo; intervals.icu lo convierte a su formato) y un `external_id` `taylorzwift-<plan>-s<semana>-<sesión>`; al volver a mandarlo se borran las anteriores (`events/bulk-delete`) y se crean de nuevo, así que cambiar la fecha de inicio no duplica nada. Con la sincronización de Garmin activada, intervals.icu las pasa a Garmin Connect y al reloj. Las salidas en exterior van como «Ride» de 3 h sin estructura.
- [x] **Tu forma** (21-nov): tarjeta en «Entrenar» con forma (CTL), cansancio (ATL) y frescura (TSB) de hoy, con su franja (perdiendo forma > 20, fresco 5–20, neutro −10–5, entrenando −30–−10, demasiado cansado < −30) y un consejo; gráfica de la forma de las 6 últimas semanas y la previsión de intervals.icu hasta el final del plan (discontinua). Sale de `GET /wellness`, que incluye los días futuros calculados con los entrenos planificados. Las salidas en exterior del plan van con carga estimada (46 por hora, la media de tus salidas de gravel) para que la previsión no las cuente como cero. Con el plan: forma de 19 a ~35 a primeros de marzo, frescura mínima −19.
- [x] **FTP sincronizado**: al cambiar el FTP en la app (a mano o al aceptar un test), a los 3 s se copia a los ajustes de ciclismo de intervals.icu (`sport-settings`).
- [x] El test de rampa cuenta como hecho a partir de 10' (acaba cuando no puedes más, no al final previsto).

### Fase 3 — Extras
Entrenos `.zwo`, exportar `.fit`, Strava/intervals.icu, rutas GPX, pulido de iPad/iPhone, mapa/visual.

- [x] **Rutas GPX** (21-nov): «⋯ → Importar GPX…» en el modo Ruta. Vale cualquier GPX con altura (recorridos de Garmin Connect, Strava, Komoot, Wikiloc). La altura se remuestrea cada 25 m, se suaviza con una media de 200 m (el GPS baila) y se trocea en tramos de 50 m con la pendiente limitada a ±20 %. Se guardan en Application Support/Rutas; perfil por colores, subidas tipo ClimbPro y adelanto de 2 km como las rutas incluidas.
- [x] **Mapa de las rutas GPX** (21-nov): tarjeta «Mapa» (MapKit) en el modo Ruta con el recorrido, lo ya hecho en gris, salida, llegada y tu posición. «Seguirme» centra el mapa en ti cada 20 m; si lo mueves, deja de seguirte. La traza (`RouteTrack`) se guarda con un punto cada 20 m como mínimo y la posición se escala por si el perfil (remuestreado) y la traza difieren un poco. Probado con una salida real de Garmin (48,6 km, 2.077 puntos, 83 ms). Las rutas GPX se leen en segundo plano al abrir la app.
- [x] **Tus recorridos de Garmin como rutas** (21-nov): descargados de intervals.icu (`/activity/{id}/gpx-file`) los GPS de las 55 salidas de gravel y agrupados por parecido (dos salidas son la misma ruta si al menos el 75 % de cada una pasa a menos de 150 m de la otra y sus longitudes no difieren más de un 25 %): **26 rutas distintas**, una por grupo (la más reciente), con nombre «Lugar km +desnivel (ida) · N veces». Se instalaron como GPX ligeros (solo posición y altura) en Application Support/Rutas. Garmin Connect no deja leer sus «Recorridos» guardados desde fuera; para esos: exportar el GPX e importarlo.
- [x] **Elegir ruta en tarjetas** (21-nov): fuera las rutas de ejemplo (Llano, Ondulado, Rompepiernas, Puerto: siguen en CicloKit para los tests); el modo Ruta enseña «Tus rutas» en una cuadrícula de 3×3 por página con mapa del recorrido, nombre, km, desnivel y año (la fecha del GPX: `<metadata><time>` o el primer punto). Orden: recientes, más suaves (m/km) o más cortas. La cuadrícula solo sale antes de empezar a rodar (cambiar de ruta pone la actividad a cero). Se recuerda la última ruta elegida. Tus 26 rutas se llaman ahora por lugar y hasta dónde llegan («Barcelona, hasta 14 km al NO · 8 veces»).
- [x] **Pantalla de ruta en tres bloques** (21-nov): arriba los datos en vivo con la marcha dentro de la misma tarjeta (número, combinación, metros por pedalada, − / + y desarrollo); en medio, el perfil completo con «Estás aquí», km hechos/que quedan, desnivel que queda, altura, pendiente actual y próximos 2 km (2/3 del ancho) junto al mapa, que te sigue solo al empezar (1/3, misma altura; en iPhone van uno debajo del otro, `SplitRow`); abajo, la subida en curso y la lista de subidas (las hechas, tachadas en gris).
- [x] **Fidelidad de los vatios** (21-nov): comparada la salida en ruta del 21-nov (1 h, 18,3 km, +350 m) contra el modelo de carretera (70 + 9,5 kg, CdA 0,32, Crr 0,005): el Kickr marca un +5 % (+3 % a +7 % según pendiente, igual en todas las marchas usadas). La marcha no cambia la medida de vatios; no se compensa hasta tener más salidas.

## 7. Decisiones de la Fase 0 (resueltas)

1. **Versiones mínimas**: iOS/iPadOS 17 y macOS 14.
2. **Licencia**: GPL-3.0.
3. **Nombre**: `taylor-zwift` para repo y carpeta local. Si algún día se publica, buscar un nombre sin «Zwift» (marca registrada).
4. **Cuenta de Apple**: gratuita por ahora.

## 8. Cómo trabajamos

Todo desde la terminal con Claude Code; VS Code (extensión Swift) para leer y editar. Xcode solo hace falta instalado.

| Comando | Qué hace |
|---|---|
| `make test` | Tests de `CicloKit` (sin hardware). |
| `make run` | Regenera el proyecto, compila la app de Mac y la abre. |
| `make build-ios` | Comprueba que compila para iPhone/iPad. |
| `make logs` | Muestra en vivo los logs de Bluetooth de la app. |

1. Claude escribe el código, pasa los tests, compila y sube los cambios.
2. Abres la app (`make run` o Claude la abre) y pruebas con el rodillo/mandos.
3. Claude lee los logs directamente (`log show`), o tú pulsas «Copiar todo» en la pestaña Log y lo pegas.
4. Claude corrige y vuelta al paso 1.

Notas:
- El `Makefile` usa el Xcode de `/Applications` aunque `xcode-select` apunte a las Command Line Tools.
- `TaylorZwift.xcodeproj` se genera con **XcodeGen** desde `App/project.yml`; está en el repo para que se pueda abrir en Xcode sin instalar nada más.
- En el Mac la app se firma localmente (sin cuenta). Para iPhone/iPad: añade tu cuenta en Xcode → Settings → Accounts y pon tu Team ID en `DEVELOPMENT_TEAM` de `App/project.yml`.

## Registro de decisiones

| Fecha | Decisión |
|---|---|
| 2026-11-18 | Swift + SwiftUI nativo multiplataforma; web descartada por falta de Web Bluetooth en iOS. |
| 2026-11-18 | Lógica en paquete `CicloKit` testeable sin hardware. |
| 2026-11-19 | Mínimos iOS/iPadOS 17 y macOS 14. |
| 2026-11-19 | Licencia GPL-3.0. |
| 2026-11-19 | Nombre unificado `taylor-zwift` (carpeta local renombrada). |
| 2026-11-19 | Cuenta de Apple gratuita por ahora. Fase 0 cerrada. |
| 2026-11-19 | Trabajo desde terminal: XcodeGen (`project.yml`) + `Makefile`; VS Code como editor. |
| 2026-11-19 | `CicloKit` dividido en `CicloKit` (lógica pura) y `CicloBluetooth` (CoreBluetooth). |
| 2026-11-19 | Prueba con hardware: Kickr conecta, control y SIM OK; los dos Click V2 conectan y leen botones. |
| 2026-11-19 | El Click **izquierdo reenvía los botones del derecho** (el derecho no reenvía los del izquierdo): con los dos conectados, cada pulsación del derecho llega dos veces, con 30–150 ms de diferencia y en cualquier orden. `ZwiftButtonAggregator` asigna un mando «dueño» a cada botón e ignora los ecos de otro mando en 0,4 s. |
| 2026-11-19 | Requisito: los dos Click V2 deben funcionar. Estrategia en capas (§5.1); la prueba B es la primera validación. |
| 2026-11-19 | **Prueba A superada** (datos, control, SIM y ERG). Prueba B: los dos mandos y todos los botones funcionan; falta la prueba de 30 min del izquierdo. |
| 2026-11-19 | Opcode `0x19` del Click = batería (campo 2, %). |
| 2026-11-19 | App aparte **Taylor Mandos** (target `TaylorMandos`): reenvía los Click V2 a MyWhoosh como mando **OpenBikeControl** por red (Bonjour `_openbikecontrol._tcp` + TCP, paquete `CicloNetwork`) y, como plan B en el Mac, como teclas K/I. Sin sandbox en macOS (simular teclas lo exige). Reconexión automática de los mandos y reconexión si un mando pasa 20 s sin mandar nada. |
| 2026-11-19 | Fase 2, primera versión: pestaña «Rodar» con rutas en SIM, 24 marchas virtuales (escalando pendiente·k, Crr·k y CdA·k³ en el comando SIM), ERG ±10 W y reconexión automática que recupera el último modo. Lógica en `CicloKit/Ride` con tests. |
| 2026-11-19 | Marchas con desarrollos reales (carretera 2×12 en 24 marchas repartidas, GRX y XPLR 1×12) y calibración del rodillo (0,356 km/h por rpm). Pulsómetro 0x180D. Vista 2D con colores de pendiente de Garmin, adelanto de 2 km y panel de subida tipo ClimbPro. |
| 2026-11-19 | Cambio de prioridad: **entrenador antes que simulador**. Pestaña «Entrenar»: FTP/zonas, biblioteca de entrenos de referencia, tests de FTP (rampa y 20'), VO2max estimado, ejecución en ERG, importar `.zwo`. Lógica en `CicloKit/Workouts` con tests. |
| 2026-11-19 | Plan de invierno de 16 semanas (desde el 23-nov-2026) a partir del histórico de Garmin; entrenos de fuerza con cadencia; zonas de pulso; biblioteca en tarjetas. |
| 2026-11-19 | Modo **Libre** (pendiente a elección y marchas), «Terminar» con resumen en todos los modos, desarrollo 1×12 por defecto y guardado. |
| 2026-11-19 | Diseño **Material 3 en SwiftUI** (tokens de color claro/oscuro, escala tipográfica, formas, botones, chips, segmentados, navegación lateral/inferior) en `App/Sources/M3.swift`; `material-components-ios` está archivado y es UIKit, así que no se usa. Rediseño de Rodar, Entrenar, detalle del entreno; pestañas nuevas Historial y Equipo. |
| 2026-11-19 | Historial con `.fit` propio y subida a Strava; Garmin Connect fuera (su API personal es solo de lectura). |
| 2026-11-19 | Sin suscripción de Strava no hay API: los entrenos van a **Garmin Connect** por importación manual asistida (botón que abre «Importar datos» y deja el `.fit` seleccionado). Strava queda como opción. |
| 2026-11-19 | Entreno en directo: «Estás aquí» sobre el perfil (entero + zoom de los próximos 20'), tu potencia real dibujada encima, y panel con velocidad, pendiente, distancia, desnivel, medias, NP/IF/TSS, kJ, W/kg, cadencia media, pulso y tiempo en zonas. En tramos ERG la velocidad sale de cadencia × marcha y la pendiente es la *equivalente* a tus vatios (`RiderPhysics`, 72 kg + 9,5 kg de bici). En tramos libres la cruceta ↑/↓ cambia la pendiente. |
| 2026-11-19 | Primer test de rampa: el mando izquierdo (8696) siguió conectado (mandaba estado) pero **no mandó ni una pulsación** en 18 min; el derecho sí. Capa 1 de §5.1: si el izquierdo pasa 60 s sin mandar botones, se reconecta solo («🔄 … lo refresco»). Falta comprobar si así se desbloquea. |
| 2026-11-19 | Datos reales: rampa → FTP 167 W (limitado por piernas/cadencia, pulso máx. 162); Z2 60' a 136 W con pulso 131–137 (71–74 % FCmáx: zona gris). **FTP de trabajo: 175 W.** Entrenos de base con **tope de pulso** (70 % FCmáx ≈ 130 ppm) y aviso para aflojar. |
| 2026-11-19 | UI: solo lo esencial. Fila principal de 3–4 datos según el modo (objetivo/potencia/cadencia/pulso con vatios fijos; potencia/velocidad/cadencia/pulso con marchas) y fila secundaria de 4 acumulados. Entreno: tarjeta del tramo (cuenta atrás + objetivo + siguiente), perfil con zoom, tramos plegados. En ERG la velocidad vuelve a ser la de llano para esa potencia y no se inventa desnivel. |
| 2026-11-21 | Seguimiento del plan cruzando historial y sesiones (`PlanProgress.swift`, con tests) y botones A (empezar/pausar) y B×2 (terminar) del mando derecho. |
| 2026-11-21 | Rutas GPX importadas (`GPXParser.swift`, con tests): rodar tus recorridos de siempre con su pendiente real. |
| 2026-11-21 | intervals.icu como destino principal de los entrenos (gratis, con API); Garmin Connect por importación manual; Strava opcional. |
| 2026-11-21 | Las salidas en exterior de Garmin entran en el plan vía intervals.icu (no hace falta leer los `.fit` de Garmin a mano) y su eFTP se propone como FTP. |
| 2026-11-21 | Segundo test de rampa: mejor minuto 245 W → **FTP 184 W** (eFTP de intervals.icu: 181), pulso máx. 170, se paró a 243 W con la cadencia cayendo. El plan empieza siempre en lunes (si eliges otro día, el lunes de esa semana): empieza el **16-nov** y esta semana es la 1 (Z2 60' el 19 y el test el 21). |
| 2026-11-21 | En el test, el Click derecho se desconectó a los 61 s sin pulsarlo («connection timed out») y el izquierdo no apareció (no se pulsó). Es el **sueño de los Click v2**: se apagan tras un rato sin usarlos (60 s–3 min según los foros de Zwift) y solo vuelven al pulsar un botón, que no cuenta. No hay forma conocida de mantenerlos despiertos. La app ahora lo llama por su nombre: «💤 dormido» en el chip de mandos y en Equipo, y al despertar avisa «Mando listo». Falta comprobar en el rodillo que la reconexión al despertar es rápida (1–2 s). |
| 2026-11-21 | Fuera Material 3: estilo **nativo de Apple** en `App/Sources/Theme.swift` (colores del sistema con claro/oscuro, naranja del sistema de acento, estilos de texto del sistema, botones `.borderedProminent`/`.bordered`, control segmentado del sistema, barra lateral `NavigationSplitView` en Mac/iPad y pestañas `TabView` en iPhone). Solo se dibujan a mano tarjetas, datos grandes, chips y los botones redondos −/+. |
| 2026-11-21 | Fuera el entreno libre (modo, tarjeta de Entrenar y su panel en Rodar; la cruceta ↑/↓ sigue en los tramos libres de un entreno). Pantallas a todo el ancho (sin `contentWidth`), márgenes de 16 pt en iPhone y 24 pt en el resto (`screenPadding()`), la marcha baja a dos filas si no cabe. Tarjetas de entreno de igual alto (nombre y descripción reservan 2 líneas) y etiqueta de zona siempre en una línea («Z7» si no cabe el nombre). |
