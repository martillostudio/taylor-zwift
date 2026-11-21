# taylor-zwift

App de entrenamiento indoor (estilo MyWhoosh/Zwift) para macOS, iPadOS e iOS, escrita en Swift/SwiftUI.

- Rodillo: Wahoo Kickr Core 2 (Bluetooth FTMS) — modos SIM y ERG.
- Mandos: Zwift Click V2 para marchas virtuales.
- Código abierto.

**Estado:** entrenador en uso con el plan de invierno de 16 semanas (desde el 23-nov-2026): entrenos en ERG, rutas en SIM con marchas virtuales, historial y sincronización con intervals.icu. Falta probar en el rodillo lo último (ver la guía, §6).

## Uso rápido

```sh
make test   # tests de la lógica (sin hardware)
make run    # compila y abre la app de Mac
make logs   # logs de Bluetooth en vivo
```

Necesitas Xcode instalado (no hace falta abrirlo). Más detalle en la guía, §8. Ver [docs/GUIA.md](docs/GUIA.md).

## Rodar

1. `make run`, pestaña **Rodar** → «Conectar rodillo y mandos». El pulsómetro se conecta solo si lo llevas puesto.
2. Elige un modo y pulsa **Empezar**:
   - **Entreno**: el entreno cargado desde «Entrenar», en ERG.
   - **Ruta**: una de tus rutas (tarjetas con mapa, km, desnivel y año) en SIM con la pendiente real. «⋯ → Importar GPX…» para añadir más (Garmin, Strava, Komoot, Wikiloc).
   - **ERG**: vatios fijos.
   En **Ruta**, el botón **«Simulador 2D»** te pone de perfil sobre el relieve de la ruta, a toda la ventana, con vatios, pulso, pendiente y marcha encima (Esc para salir).
3. Mandos: **+ (dcha) o Z** = marcha más dura (+10 W en ERG, +2 % en un entreno); **− (izq) o Y** = más blanda. **A** empieza / pausa; **B** dos veces seguidas termina y guarda.
4. Desarrollo: carretera 2×12 (24 marchas), GRX 1×12 o SRAM XPLR 1×12.

**Sin el rodillo cerca:** «Probar sin rodillo» (en Rodar o en Equipo › Rodillo) conecta un rodillo, un pulsómetro y unos mandos de mentira. Eliges cuánto empuja el ciclista en ruta, aceleras el tiempo (×10 o ×30, para hacer un entreno entero en minutos) y pulsas los botones de los Click en pantalla. No se guarda ni se sube nada, y el FTP no cambia.

## Entrenar

- **Tu perfil:** FTP, peso y zonas. El FTP se actualiza solo: con un test hecho a tope (pulso ≥ 92 % de la FC máx.) o cuando el eFTP de intervals.icu sube 5 W o más.
- **Plan «Invierno en el rodillo»** (16 semanas, 3 sesiones/semana): «Hoy toca» con botón para ir al entreno; las sesiones se marcan solas al hacerlas (también las salidas en exterior, vía intervals.icu). Clic derecho para marcar a mano o **cambiar de día** dentro de la semana.
- **Propuestas para tu plan:** si te saltas una sesión dura, vas muy cansado, los intervalos te salen por debajo dos veces o siempre ajustas con − / +, la app propone un cambio concreto (otro día, algo más suave, otra intensidad para ese tipo). Solo cambia si pulsas «Aceptar», y entonces se actualiza también en intervals.icu.
- **Tu progreso y Tu forma:** qué conviene hoy, fases del plan, carga semanal hecha vs prevista, eFTP y mejores marcas, y forma/cansancio/frescura con su previsión.
- **Al terminar un entreno:** cómo fue cada intervalo frente a lo previsto, la cadencia en los de fuerza, si el pulso derivó en los rodajes de Z2 y si pasaste el tope de pulso, y un consejo para la próxima vez. También en el detalle de cada entreno del Historial.
- **Biblioteca:** Z2, sweet spot, umbral, VO2max 4×4, 30/15, fuerza a baja cadencia, tests de rampa y 20'… o importa un `.zwo`. «Cargar este entreno» → «Empezar».

## Historial, intervals.icu, Garmin Connect y Strava

Cada entreno de más de 1 minuto se guarda al terminar (pestaña **Historial**), con su `.fit` para exportarlo.

**intervals.icu (recomendado, gratis):** en Historial, pega tu clave de API (intervals.icu → Settings → Developer Settings). Cada entreno se sube solo al terminar, el plan aparece en su calendario (y en Garmin Connect y el reloj si tienes la sincronización activada) y se vuelve a mandar solo cuando lo cambias.

**Garmin Connect:** al terminar (se puede desactivar) o con «Subir a Garmin Connect» en el resumen o el historial, se abre su página de importar y te deja el `.fit` seleccionado en el Finder: arrástralo a la página (mejor con Chrome o Edge).

**Strava (opcional, necesita suscripción para usar su API):**
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
