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

### Estructura de carpetas prevista

```
taylor-zwift/
├── README.md
├── docs/                    ← esta guía y notas técnicas
├── App/                     ← proyecto de Xcode (SwiftUI)
│   └── TaylorZwift.xcodeproj
└── CicloKit/                ← paquete Swift con la lógica
    ├── Package.swift
    ├── Sources/
    │   ├── FTMS/            ← parseo y comandos del rodillo (bytes ↔ structs)
    │   ├── ZwiftClick/      ← parseo de botones del Click V2
    │   ├── Physics/         ← potencia → velocidad, marchas virtuales
    │   ├── Workouts/        ← entrenos (.zwo) — Fase 3
    │   └── Bluetooth/       ← capa CoreBluetooth (solo Apple)
    └── Tests/
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
- Mando derecho (+, A, B, Y, Z) funciona libre. **El izquierdo está bloqueado para Zwift** (ver riesgos).

Referencias (solo para leer, no copiar código): BikeControl (protocolo Click), Auuki (FTMS y física). Ver doc del proyecto «repos-y-protocolos».

## 5. Riesgos y cómo los atacamos

| Riesgo | Impacto | Qué haremos |
|---|---|---|
| **Mando izquierdo del Click V2 bloqueado** | Solo un mando útil | Diseñar las marchas para que funcionen **solo con el derecho** (p. ej. `+` sube, `A`/`B` bajan…). El izquierdo, como extra si se desbloquea. |
| **Una sola app controlando el rodillo** | Si Zwift/MyWhoosh/Wahoo están abiertos, no conectamos o no nos deja controlar | Cerrar esas apps al probar. La app mostrará un error claro si el control point rechaza `0x00`. |
| **Mandos emparejados con el rodillo** (Kickr Core 2 + Zwift) | El Click puede estar vinculado al rodillo y no anunciarse a nosotros | Comprobarlo en la prueba B (Fase 1). |
| **Caducidad 7 días (cuenta gratuita)** | Molestia en iPhone/iPad | Iterar en el Mac; decidir cuenta de pago más adelante. |
| **Claude no puede ejecutar Xcode ni Bluetooth** | Bucle de prueba más lento | Lógica pura con tests; logs claros en pantalla para que copies y pegues lo que ves. |

## 6. Plan por fases

### Fase 0 — Guía (esta) ✅
Salida: este documento + decisiones pendientes resueltas (ver §7 y registro).

### Fase 1 — Pruebas de riesgo («spikes»)
Dos pantallas mínimas dentro de la app, sin diseño:

- **Prueba A — Rodillo**
  - [ ] Escanea y lista dispositivos FTMS.
  - [ ] Conecta al Kickr y muestra potencia, cadencia y velocidad en vivo.
  - [ ] Pide control (`0x00`) y cambia la pendiente (`0x11`) con un slider: notas la resistencia.
  - [ ] Pone 150 W en ERG (`0x05`).
- **Prueba B — Mandos**
  - [ ] Escanea y encuentra el Click V2 derecho (y el izquierdo si se deja).
  - [ ] Hace el handshake `RideOn`.
  - [ ] Muestra en pantalla qué botón pulsas.

Criterio para pasar a Fase 2: A y B funcionan **en el Mac**. Si algo falla, se corrige el plan aquí antes de seguir.

### Fase 2 — MVP para entrenar
- Pantalla de rodaje: potencia, cadencia, velocidad, distancia, tiempo, pendiente, marcha.
- Modo **SIM**: ruta simple (perfil de pendientes) → física → pendiente al rodillo.
- **Marchas virtuales** con los mandos (cambian la resistencia efectiva).
- Modo **ERG** con potencia fija.
- Reconexión automática.

### Fase 3 — Extras
Entrenos `.zwo`, exportar `.fit`, Strava/intervals.icu, rutas GPX, pulido de iPad/iPhone, mapa/visual.

## 7. Decisiones de la Fase 0 (resueltas)

1. **Versiones mínimas**: iOS/iPadOS 17 y macOS 14.
2. **Licencia**: GPL-3.0.
3. **Nombre**: `taylor-zwift` para repo y carpeta local. Si algún día se publica, buscar un nombre sin «Zwift» (marca registrada).
4. **Cuenta de Apple**: gratuita por ahora.

## 8. Cómo trabajamos

1. Claude escribe código y documentación en el repo.
2. Tú haces `git pull`, abres el proyecto en Xcode y pulsas ▶︎ con destino «My Mac».
3. Pruebas con el rodillo/mandos y pegas a Claude lo que ves (pantalla de logs o error de Xcode).
4. Claude corrige y vuelta al paso 2.

## Registro de decisiones

| Fecha | Decisión |
|---|---|
| 2026-11-18 | Swift + SwiftUI nativo multiplataforma; web descartada por falta de Web Bluetooth en iOS. |
| 2026-11-18 | Lógica en paquete `CicloKit` testeable sin hardware. |
| 2026-11-19 | Mínimos iOS/iPadOS 17 y macOS 14. |
| 2026-11-19 | Licencia GPL-3.0. |
| 2026-11-19 | Nombre unificado `taylor-zwift` (carpeta local renombrada). |
| 2026-11-19 | Cuenta de Apple gratuita por ahora. Fase 0 cerrada. |
