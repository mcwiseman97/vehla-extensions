# Antinote Dock Widget 1.1.1

The immutable ZIP is signed by **Michael Wiseman**.

- Publisher ID: `com.wiseman.publisher`
- Key ID: `release-2026-10`
- Ed25519 public key (base64): `nmRkk5loQ0WZxoSG9o4bvERGEseRT5k/tIybSlY2j14=`
- SHA-256 fingerprint of the raw public-key bytes: `56b2149c50ae60489722f1bee054185e57056e217c60b5eee87f3a2fd0dc1b0d`

ZIP SHA-256: `d6a45b63bd15dc8312f3d6d71b2d44112b7810f6cfa86c1cc2cbb0a125883c28`

`antinote-dock-widget-1.1.1.signature.json` contains the public publisher identity and the Ed25519 archive signature. The private key is kept in the publisher's macOS Keychain and is never included in this repository. Preserve released ZIPs byte-for-byte.

Verify:

```sh
swift scripts/publisher-signing.swift verify \
  extensions/antinote-dock-widget/releases/antinote-dock-widget-1.1.1.zip \
  nmRkk5loQ0WZxoSG9o4bvERGEseRT5k/tIybSlY2j14= \
  MVG+HdogKTVwKnKKqcJK3FKz9NG8ZY/BSEFwaqbro2Sn1yfZdqaxDs7e65v9UQscBqA4fjbdmE4dYM5quXmSBg==
```
