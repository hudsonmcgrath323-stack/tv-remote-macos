# Contributing to TV Remote

Thank you for your interest in contributing to **TV Remote**! Contributions from macOS developers, Python/`pyatv` tinkerers, and Apple TV smart-home enthusiasts are very welcome.

## Ways to Contribute

- **Bug Reports**: Open a [Bug Report](https://github.com/hudsonmcgrath323-stack/tv-remote-macos/issues/new/choose) with your macOS version, tvOS version, Apple TV model, and audio output setup (TV speakers, HDMI-CEC, eARC, or HomePod).
- **Feature Requests**: Suggest enhancements via the [Feature Request](https://github.com/hudsonmcgrath323-stack/tv-remote-macos/issues/new/choose) template.
- **Pull Requests**: Fix bugs, improve accessibility, or expand protocol support.

## Development Setup

1. **Fork and clone** the repository:
   ```bash
   git clone https://github.com/<your-username>/tv-remote-macos.git
   cd tv-remote-macos
   ```
2. **Set up the isolated Python helper environment**:
   ```bash
   ./scripts/setup_python.sh
   ```
3. **Run the Python bridge unit tests**:
   ```bash
   "$HOME/Library/Application Support/TVRemote/venv/bin/python3" -m unittest discover -s tests -v
   ```
4. **Build the Swift 6 app**:
   ```bash
   swift build -c release
   # Or package the standalone .app bundle into ./dist/TV Remote.app:
   ./scripts/build_app.sh
   ```

### Testing Without a Physical Apple TV

You can launch TV Remote against `MockAppleTVService` scenarios without needing a paired Apple TV on the network:

```bash
swift run TVRemote --mock-connected
swift run TVRemote --mock-pairing
swift run TVRemote --mock-no-volume
```

## Architecture & Coding Guidelines

- **Swift 6 Strict Concurrency**: All UI state is `@MainActor` (`@Observable`), and process/stdio management lives inside `BridgeProcessActor`. Avoid blocking the main thread.
- **Native Liquid Glass APIs**: Use native `.glassEffect(.regular, in:)`, `GlassEffectContainer`, `.buttonStyle(.glass)` / `.glassProminent`, and `.glassEffectID`. Apply `.glassEffect` directly to foreground content containers rather than `Color.clear` inside `.background` when inside a `GlassEffectContainer`, and always support `accessibilityReduceTransparency`, `accessibilityReduceMotion`, and `colorSchemeContrast`.
- **Credential Hygiene**: Never log, print, or write Companion/AirPlay credentials to disk. All pairing credentials belong exclusively in `KeychainStore`.
- **Conventional Commits**: Please use clear commit prefixes (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).

## License

By contributing to TV Remote, you agree that your contributions will be licensed under the [MIT License](LICENSE).
