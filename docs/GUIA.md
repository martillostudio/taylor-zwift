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
- [x] **Marchas virtuales** (24, de 0,5× a 1,7×): ver abajo.
- [x] Modo **ERG** con los mismos botones (±10 W).
- [x] **Reconexión automática** del rodillo y los mandos; al volver, el rodillo recupera el último modo. Botón «Conectar rodillo y mandos».
- [ ] Probarlo en el rodillo: ¿se notan las marchas en llano y en subida? ¿Respeta el Kickr el Crr y el CdA del comando SIM?

**Cómo funcionan las marchas virtuales.** El rodillo tiene un desarrollo real fijo: la velocidad de su volante solo depende de la cadencia. Para una marcha *k* veces más dura, la velocidad «de carretera» es *k* veces la del volante y hay que pedir *k* veces la fuerza de pendiente y rodadura y *k³* la del aire:
`F' = k·m·g·(pendiente + Crr) + k³·½ρCdA·v²`. Eso se consigue mandando en el comando SIM `pendiente·k`, `Crr·k` y `CdA·k³`; el rodillo hace el resto con su física, sin bucles de control. El tope de 1,7× sale del máximo de CdA de FTMS (2,55 kg/m con 0,51 de base). Código: `CicloKit/Ride/VirtualGears.swift`.

**Botones** (los mismos que «Taylor Mandos»): + (dcha) o Z, marcha más dura / +10 W; − (izq) o Y, más blanda / −10 W.

### Fase 3 — Extras
Entrenos `.zwo`, exportar `.fit`, Strava/intervals.icu, rutas GPX, pulido de iPad/iPhone, mapa/visual.

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
