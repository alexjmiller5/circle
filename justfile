# Circle developer interface. Derived data stays outside cloud-synced source.
derived := env_var_or_default("CIRCLE_DERIVED_DATA", env_var("HOME") + "/Library/Developer/Xcode/DerivedData/Circle")
destination := env_var_or_default("CIRCLE_DESTINATION", "platform=macOS")

gen:
    "$(realpath "$(command -v xcodegen)")" generate

check: gen
    xcodebuild -project Circle.xcodeproj -scheme Circle -destination '{{destination}}' -derivedDataPath '{{derived}}' CODE_SIGN_IDENTITY=- -jobs 2 build

test:
    swift test --jobs 2
    uv run --with pytest pytest tests/

test-ui: gen
    xcodebuild -project Circle.xcodeproj -scheme Circle -destination '{{destination}}' -derivedDataPath '{{derived}}' CODE_SIGN_IDENTITY=- -jobs 2 -parallel-testing-enabled NO -collect-test-diagnostics never test

run *ARGS: check
    open -n '{{derived}}/Build/Products/Debug/Circle.app' --args {{ARGS}}

# --- project-specific ---
calls *ARGS:
    uv run scripts/call_log.py {{ARGS}}
