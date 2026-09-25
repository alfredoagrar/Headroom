# Headroom

Barra de menú para macOS 26+ que muestra tus límites de uso de IA (Claude, Codex…) en un popover Liquid Glass. Ver [SPEC.md](SPEC.md).

## Requisitos
- macOS 26, Xcode 26+, `brew install xcodegen`
- Sesión iniciada en los CLIs: `claude auth login`, `codex login`

## Desarrollo
```bash
xcodegen generate                      # regenera Headroom.xcodeproj desde project.yml
xcodebuild -scheme Headroom test       # tests (fixtures reales en HeadroomTests/Fixtures)
xcodebuild -scheme Headroom build && open ~/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app
```
> No uses `-derivedDataPath` dentro de `~/Documents`: iCloud agrega atributos extendidos y `codesign` falla.

## Probar endpoints a mano
```bash
./Scripts/probe_claude.sh
./Scripts/probe_codex.sh
```
