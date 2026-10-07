.PHONY: app debug run test release install clean snapshot

app:            ## Build release (arquitetura atual) → build/Rosen.app
	@Scripts/build.sh release

debug:          ## Build debug
	@Scripts/build.sh debug

run: debug      ## Build debug e abre o app
	@pkill -x Rosen 2>/dev/null || true
	@open build/Rosen.app

test:           ## Testes do núcleo (parser, cofre, ssh, FIFO)
	@Scripts/build.sh test

release:        ## Zip universal + atualiza Casks/rosen.rb (make release V=0.2.0)
	@Scripts/release.sh $(V)

install: app    ## Copia para /Applications
	@pkill -x Rosen 2>/dev/null || true
	@rm -rf /Applications/Rosen.app
	@cp -R build/Rosen.app /Applications/
	@echo "✓ /Applications/Rosen.app"

clean:
	@rm -rf build dist .build

snapshot:       ## Renderiza as telas em build/snapshots (revisão visual)
	@Scripts/build.sh snapshot
