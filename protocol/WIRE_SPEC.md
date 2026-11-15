# LinkMyMac Wire Protocol & Cryptographic Specification (v1.0)

## 1. Transport Layer & Port Binding
- **Service Type (mDNS / DNS-SD):** `_linkmymac._tcp.local.`
- **Default TCP Port:** `8765` (Control + Multiplexed Stream), `8766` (Optional dedicated Bulk Binary Stream)
- **USB ADB Tunnel Fallback:** `adb forward tcp:8765 tcp:8765` (binds to `127.0.0.1:8765`)

## 2. Length-Delimited Framing Format
Every packet sent over the TLS 1.3 socket is prefixed with an 8-byte header:

```
+-------------------+-------------------+-----------------------------------+
| Magic (2 bytes)   | Flags (2 bytes)   | Payload Length (4 bytes, uint32)  |
| 0x4C 0x4D ("LM")  | 0x0001 (Protobuf) | Big-Endian Length (Max 16 MB)     |
+-------------------+-------------------+-----------------------------------+
|                        Payload Bytes (N bytes)                            |
+---------------------------------------------------------------------------+
```

- **Magic Bytes:** `0x4C 0x4D` (`"LM"`) validates frame synchronization.
- **Flags:**
  - `0x0001`: Standard Protobuf/JSON Control Frame (`LMMFrame`)
  - `0x0002`: Raw Binary File Chunk Frame
  - `0x0004`: Compressed Frame (LZ4)
- **Payload Length:** 32-bit unsigned big-endian integer indicating exact byte length of the following message.

## 3. Out-of-Band QR Pairing & mTLS Handshake
1. **QR Code Payload (Generated on Android):**
   ```json
   {
     "v": 1,
     "name": "Galaxy S25 Ultra",
     "ips": ["192.168.1.45", "192.168.43.1"],
     "port": 8765,
     "certFp": "SHA256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
     "nonce": "7d8a9b0c1e2f3a4b5c6d7e8f9a0b1c2d"
   }
   ```
2. **TLS Certificate Pinning:**
   - Both macOS and Android generate a self-signed X.509 certificate backed by hardware keys (`AndroidKeyStore` EC/Ed25519 on Android; `CryptoKit` / Keychain on macOS).
   - During the TLS 1.3 handshake, the custom `X509TrustManager` (Android) and `sec_protocol_options_set_verify_block` (macOS) verify that the peer's leaf certificate SHA-256 digest matches `certFp` from the QR code (or saved trust store).
3. **Application-Layer Challenge (`PairingHandshake`):**
   - Immediately after TLS establishment, macOS sends a `PairingHandshake` frame containing its `device_id`, `device_name`, and an Ed25519 signature over `(device_id || peer_cert_fp || ephemeral_nonce)`.
   - Android verifies the signature and responds with `PairingAck(accepted = true)`. Both peers persist the peer certificate fingerprint for automatic background reconnection.
