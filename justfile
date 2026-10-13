# Circle developer interface. Derived data stays outside cloud-synced source.
derived := env_var_or_default("CIRCLE_DERIVED_DATA", env_var("HOME") + "/Library/Developer/Xcode/DerivedData/Circle")
destination := env_var_or_default("CIRCLE_DESTINATION", "platform=macOS")

gen:
    "$(realpath "$(command -v xcodegen)")" generate

check: gen
    xcodebuild -project Circle.xcodeproj -scheme Circle -destination '{{destination}}' -derivedDataPath '{{derived}}' CODE_SIGN_IDENTITY=- -jobs 2 build

test:
    swift test --jobs 2 --scratch-path '{{derived}}/SwiftPM'
    uv run --with pytest pytest tests/ scripts/sign_ios_test.py scripts/ios_workflow_test.py scripts/ota_install_test.py

test-ui: gen
    xcodebuild -project Circle.xcodeproj -scheme Circle -destination '{{destination}}' -derivedDataPath '{{derived}}' CODE_SIGN_IDENTITY=- -jobs 2 -parallel-testing-enabled NO -collect-test-diagnostics never test

run *ARGS: check
    open -n '{{derived}}/Build/Products/Debug/Circle.app' --args {{ARGS}}

# Add a verified Ad Hoc .ipa to this machine's shared tailnet install page
# (https://<tailnet name>/install/; listed OTA_TTL_HOURS, default 48).
ota ipa="build/Circle.ipa":
    ./scripts/ota-install.py "{{ipa}}"

# --- project-specific ---
calls *ARGS:
    uv run scripts/call_log.py {{ARGS}}
