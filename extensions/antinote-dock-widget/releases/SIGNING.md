# Antinote Dock Widget 1.1.1

The immutable ZIP is signed by **Michael Wiseman**.

- Publisher ID: `com.wiseman.publisher`
- Key ID: `release-2026-10`
- Ed25519 public key (base64): `nmRkk5loQ0WZxoSG9o4bvERGEseRT5k/tIybSlY2j14=`
- SHA-256 fingerprint of the raw public-key bytes: `56b2149c50ae60489722f1bee054185e57056e217c60b5eee87f3a2fd0dc1b0d`

ZIP SHA-256: `cfe28e5c729359df711b2841d08d7e440396c281ff83794a99a709c8384aee3b`

`antinote-dock-widget-1.1.1.signature.json` contains the public publisher identity and the Ed25519 archive signature. The private key is kept in the publisher's macOS Keychain and is never included in this repository. Preserve released ZIPs byte-for-byte.

Verify:

```sh
swift scripts/publisher-signing.swift verify \
  extensions/antinote-dock-widget/releases/antinote-dock-widget-1.1.1.zip \
  nmRkk5loQ0WZxoSG9o4bvERGEseRT5k/tIybSlY2j14= \
  xkId/r9zdsMVHbZFc/p5OJCpiT8Ixn0Mg5boemVlQDH+QinVxr75gw7hj03SmiB/4UpU4p1AHgWIJh5E6P2ZAA==
```
