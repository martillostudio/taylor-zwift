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

## Entrenos (pestaña «Entrenar»)

1. Pon tu **FTP** y tu peso (o haz el **test de rampa**: al acabar te propone el FTP).
2. Elige un entreno de la biblioteca (Z2, sweet spot, umbral, VO2max 4×4, 30/15…) o importa un `.zwo`.
3. «Cargar este entreno» → «Empezar». El rodillo va en ERG; los Click suben/bajan la intensidad un 2 %.

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

## Licencia

GPL-3.0. Ver [LICENSE](LICENSE).
