#!/usr/bin/env swift
import Foundation
import CryptoKit
import Security

// The private key never leaves Keychain except in this process's memory.
let service = "com.0xdarkkernel.vehla.publisher"
let account = "release-2026-09"
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
guard CommandLine.arguments.count == 3 else { fail("Usage: swift sign-release.swift <immutable-zip> <public-signature-json>") }
let archiveURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
var lookup = query
lookup[kSecReturnData as String] = true
lookup[kSecMatchLimit as String] = kSecMatchLimitOne
var result: CFTypeRef?
let status = SecItemCopyMatching(lookup as CFDictionary, &result)
let key: Curve25519.Signing.PrivateKey
do {
    if status == errSecSuccess, let data = result as? Data {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    } else if status == errSecItemNotFound {
        key = Curve25519.Signing.PrivateKey()
        var item = query
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrLabel as String] = "0xdarkkernel Vehla publisher (release-2026-09)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let saved = SecItemAdd(item as CFDictionary, nil)
        guard saved == errSecSuccess else { fail("Keychain save failed: \(saved)") }
    } else { fail("Keychain lookup failed: \(status)") }
    let bytes = try Data(contentsOf: archiveURL)
    let signature = try key.signature(for: bytes)
    guard key.publicKey.isValidSignature(signature, for: bytes) else { fail("Signature verification failed") }
    let publicKey = key.publicKey.rawRepresentation
    let metadata: [String: Any] = [
        "publisher": ["id": "com.0xdarkkernel.publisher", "name": "0xdarkkernel", "keyID": account, "publicKey": publicKey.base64EncodedString()],
        "signature": signature.base64EncodedString(),
        "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        "publicKeyFingerprintSHA256": SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    ]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL, options: .atomic)
    print("Signed and verified \(archiveURL.lastPathComponent). Public metadata: \(outputURL.path)")
} catch { fail(error.localizedDescription) }
