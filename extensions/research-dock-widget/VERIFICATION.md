# Local verification

Verified on this Apple silicon development machine with Swift 6.4 Command Line Tools:

- 26 Swift Testing tests passed (live network and render checks run separately), including the five parameterized HTTP rejection cases.
- Live public-page extraction succeeded for https://www.swift.org/blog/announcing-swift-6/ (86 text blocks).
- Offscreen AppKit previews rendered and were visually inspected at 760 × 800 points in light and dark appearances.
- A 1,000-article cached library loaded in approximately 94 ms; a metadata edit took approximately 22 ms in the final test run. These are local observations, not performance guarantees.
- Release bundle built for arm64 and ad hoc signed.
- `vehla-swift validate` accepted the final installable package.
- Bundle SDK load path points to Vehla's embedded `VehlaDockWidgetSDK.framework`.

The package has not been installed into the user's Vehla profile. Live host panel placement, host permission dialogs, keyboard/VoiceOver operation, and real clipboard bridge integration still need in-app acceptance testing. Preview tests exercise native view rendering and model tests exercise the fallback path; they do not replace that host test.

The catalog has not been modified or published. No SDK or host source changes were required.

Earlier theme follow-up: matched Hertzly’s transparent popup and host-provided text palette, replaced serif headings with system typography, and applied host text/link colors to the native reader. Re-ran the test suite with rendered previews enabled (live network check skipped on this visual-only update). Light/dark previews regenerated.

Latest UI: inline forms and confirmations, white controls, custom swipe-to-reveal Delete with Undo, four-second status messages and an eight-second Undo window. The revealed Delete button was rendered and inspected on a gray background. Trackpad interaction still requires final host acceptance.

## Publisher identity

- Publisher ID: `com.0xdarkkernel.publisher`
- Publisher name: `0xdarkkernel`
- Key ID: `release-2026-09`
- Ed25519 public key (base64): `PXFv8wNTyjdThFfGtILeAaY/xTKo6noi2obbf8QtKAI=`
- SHA-256 fingerprint of raw public-key bytes: `4ad1b80d1b40de4438bfb604728a8040eacb86632b7128693d8f6b767ab8cdd7`

This key authenticates Research releases. The private key is stored in the publisher's macOS Keychain and is never included in this repository.

Research 1.0.0 ZIP SHA-256: `e8a0f07b7c376f5c74a4c1bdbe147b6e4ff44d00b73980268e43829550c4b6f2`. The exact ZIP and detached public signature metadata are in `releases/`. The ad-hoc bundle signature and Ed25519 archive signature have both been verified.
