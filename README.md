# taylor-zwift

App de entrenamiento indoor (estilo MyWhoosh/Zwift) para macOS, iPadOS e iOS, escrita en Swift/SwiftUI.

- Rodillo: Wahoo Kickr Core 2 (Bluetooth FTMS) — modos SIM y ERG.
- Mandos: Zwift Click V2 para marchas virtuales.
- Código abierto.

**Estado:** Fase 2 — pestaña «Rodar» para entrenar: rutas en modo SIM con 24 marchas virtuales, ERG y reconexión automática (falta probarla en el rodillo).

## Uso rápido

```sh
make test   # tests de la lógica (sin hardware)
make run    # compila y abre la app de Mac
make logs   # logs de Bluetooth en vivo
```

Necesitas Xcode instalado (no hace falta abrirlo). Más detalle en la guía, §8. Ver [docs/GUIA.md](docs/GUIA.md).

## Entrenar (pestaña «Rodar»)

1. `make run`, pestaña **Rodar** → «Conectar rodillo y mandos».
2. Elige **Ruta (SIM)** y una ruta, o **ERG**, y pulsa **Empezar**.
3. Mandos: **+ (dcha) o Z** = marcha más dura (+10 W en ERG); **− (izq) o Y** = más blanda (−10 W).
4. Desarrollo: carretera 2×12 (24 marchas), GRX 1×12 o SRAM XPLR 1×12. El pulsómetro se conecta solo si lo llevas puesto.

## Entreno libre

Pestaña **Rodar → Libre** (o «Rodar libre» en Entrenar): eliges la pendiente con el deslizador, los atajos o la cruceta ↑/↓ del mando izquierdo, y cambias de marcha con + / − como siempre. «Terminar» te da el resumen.

## Entrenos (pestaña «Entrenar»)

1. Pon tu **FTP** y tu peso (o haz el **test de rampa**: al acabar te propone el FTP).
2. Elige un entreno de la biblioteca (Z2, sweet spot, umbral, VO2max 4×4, 30/15…) o importa un `.zwo`.
3. «Cargar este entreno» → «Empezar». El rodillo va en ERG; los Click suben/bajan la intensidad un 2 %.

## Historial, Garmin Connect y Strava

**Garmin Connect:** en el resumen o en el historial, «Subir a Garmin Connect» abre su página de importar y te deja el `.fit` seleccionado en el Finder: arrástralo a la página (mejor con Chrome o Edge).

**Strava (opcional, necesita suscripción para usar su API):**

Cada entreno de más de 1 minuto se guarda al terminar (pestaña **Historial**), con su `.fit` para exportarlo.

Para subirlos a Strava:
1. En [strava.com/settings/api](https://www.strava.com/settings/api) crea una aplicación con **Authorization Callback Domain = `localhost`**.
2. En Historial, pega su *Client ID* y *Client Secret* y pulsa «Conectar con Strava».
3. Con «Subir al terminar» activado, cada entreno se sube solo (marcado como entreno en rodillo).

## Taylor Mandos: los Click V2 como mando de MyWhoosh

App pequeña e independiente (misma base de código) que conecta los dos Zwift Click V2
y reenvía cada pulsación a MyWhoosh:

```sh
make mandos            # compila y abre «Taylor Mandos» en el Mac (para desarrollar)
make instalar-mandos   # versión final en /Applications: luego se abre con doble clic
```

1. Cierra Zwift y cualquier otra app de mandos (si no, se quedan con los Click).
2. Abre Taylor Mandos y pulsa un botón de cada Click: se conectan solos (y se reconectan si se caen).
3. En MyWhoosh: pantalla de conexión → icono de **OpenBikeControl** (arriba a la derecha) → «Taylor Mandos».
   MyWhoosh puede estar en el mismo Mac o en el iPad/iPhone, con la misma wifi.
4. Plan B (solo si MyWhoosh está en el Mac): activa «Teclado (K / I)» y da el permiso de Accesibilidad.
   Usa solo una salida a la vez.

| Botón | Acción |
|---|---|
| + (dcha) / Z | Subir marcha |
| − (izq) / Y | Bajar marcha |
| Cruceta (izq) | Navegar por menús |
| A / B | Aceptar / Atrás |

Y y Z repiten las marchas por si el mando izquierdo se bloquea (ver la guía, §5.1).

Los Click v2 se duermen tras un rato sin pulsarlos (para ahorrar batería): la primera pulsación solo los despierta y la app avisa con «Mando listo».

## Licencia

GPL-3.0. Ver [LICENSE](LICENSE).
