# Atajos para trabajar desde la terminal (Claude Code / VS Code) sin abrir Xcode.
# Usa el Xcode de /Applications aunque xcode-select apunte a las Command Line Tools.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

XCODEGEN ?= $(shell command -v xcodegen || echo $(HOME)/.local/bin/xcodegen)
PROJECT  := App/TaylorZwift.xcodeproj
DERIVED  := build/DerivedData
APP      := $(DERIVED)/Build/Products/Debug/TaylorZwift.app
MANDOS   := $(DERIVED)/Build/Products/Debug/TaylorMandos.app

.PHONY: escenarios test project build build-ios run logs clean build-mandos mandos build-mandos-ios instalar-mandos

test:            ## Tests de CicloKit (sin hardware)
	cd CicloKit && swift test

project:         ## Regenera el .xcodeproj desde App/project.yml (si xcodegen está instalado)
	@if [ -x "$(XCODEGEN)" ] || command -v "$(XCODEGEN)" >/dev/null 2>&1; then \
		cd App && "$(XCODEGEN)" generate; \
	else \
		echo "Aviso: xcodegen no está instalado; uso el $(PROJECT) del repo (brew install xcodegen para regenerarlo)."; \
	fi

build: project   ## Compila la app de Mac
	xcodebuild -project $(PROJECT) -scheme TaylorZwift -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DERIVED) -quiet build

build-ios: project ## Comprueba que compila para iPhone/iPad (sin firmar)
	xcodebuild -project $(PROJECT) -scheme TaylorZwift -destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED) -quiet CODE_SIGNING_ALLOWED=NO build

run: build       ## Compila y abre la app de Mac
	open $(APP)

build-mandos: project ## Compila «Taylor Mandos» (Click V2 → MyWhoosh) para Mac
	xcodebuild -project $(PROJECT) -scheme TaylorMandos -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DERIVED) -quiet build

mandos: build-mandos ## Compila y abre «Taylor Mandos»
	open $(MANDOS)

instalar-mandos: project ## Compila la versión final y la copia a /Applications (doble clic, Launchpad, Spotlight)
	xcodebuild -project $(PROJECT) -scheme TaylorMandos -configuration Release \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet build
	@pkill -x TaylorMandos 2>/dev/null || true
	rm -rf "/Applications/Taylor Mandos.app"
	ditto "$(DERIVED)/Build/Products/Release/TaylorMandos.app" "/Applications/Taylor Mandos.app"
	@echo "✅ Instalada en /Applications/Taylor Mandos.app"
	open "/Applications/Taylor Mandos.app"

build-mandos-ios: project ## Comprueba que «Taylor Mandos» compila para iPhone/iPad
	xcodebuild -project $(PROJECT) -scheme TaylorMandos -destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED) -quiet CODE_SIGNING_ALLOWED=NO build

logs:            ## Muestra en vivo los logs de Bluetooth de la app
	/usr/bin/log stream --style compact --predicate 'subsystem == "studio.martillo.taylorzwift"'

clean:
	rm -rf build

escenarios: ## Copia los fondos de pixel art (packs descargados en el Escritorio) a App/Escenarios
	tools/instalar-escenarios.sh
