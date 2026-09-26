# Research 1.0.0

The immutable ZIP is signed by **0xdarkkernel**.

SHA-256: `e8a0f07b7c376f5c74a4c1bdbe147b6e4ff44d00b73980268e43829550c4b6f2`

`research-dock-widget-1.0.0.signature.json` contains the public publisher identity and Ed25519 archive signature. See `../VERIFICATION.md` for the public-key fingerprint. `../scripts/sign-release.swift` signs future archives using the existing key in macOS Keychain; it never prints or writes the private key. Preserve released ZIPs byte-for-byte.
