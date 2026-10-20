.PHONY: check test deploy-check

check:
	git diff --check
	@for script in scripts/*.sh; do bash -n "$$script" || exit; done
	./scripts/check-spacing-tokens.sh
	./scripts/check-localization.sh

# 与 CI 同款：必须用 test 而非 build，否则 ClipinTests target 不编译。
test:
	xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug \
		-destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test

deploy-check: check
	xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build -quiet
