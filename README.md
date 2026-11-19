# taylor-zwift

App de entrenamiento indoor (estilo MyWhoosh/Zwift) para macOS, iPadOS e iOS, escrita en Swift/SwiftUI.

- Rodillo: Wahoo Kickr Core 2 (Bluetooth FTMS) — modos SIM y ERG.
- Mandos: Zwift Click V2 para marchas virtuales.
- Código abierto.

**Estado:** Fase 1 — pruebas con rodillo y mandos (código listo, falta probar con el hardware).

## Uso rápido

```sh
make test   # tests de la lógica (sin hardware)
make run    # compila y abre la app de Mac
make logs   # logs de Bluetooth en vivo
```

Necesitas Xcode instalado (no hace falta abrirlo). Más detalle en la guía, §8. Ver [docs/GUIA.md](docs/GUIA.md).

## Licencia

GPL-3.0. Ver [LICENSE](LICENSE).
