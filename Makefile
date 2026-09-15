.PHONY: check deploy-check

check:
	git diff --check
	@for script in scripts/*.sh; do bash -n "$$script" || exit; done
	./scripts/check-spacing-tokens.sh
	./scripts/check-localization.sh

deploy-check: check
	xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build -quiet
