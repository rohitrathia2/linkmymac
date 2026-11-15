# LinkMyMac Wire Protocol (v1.1)

What both apps actually speak today. `linkmymac_protocol.proto` sketches a future binary schema and is not used on the wire.

## 1. Transport
- The phone listens on **TCP 8765** and advertises **`_linkmymac._tcp.local.`** over mDNS/DNS-SD.
- USB: `adb forward tcp:8765 tcp:8765`, then the Mac connects to `127.0.0.1:8765`.
- Plain TCP. **There is no TLS yet** (see §6).

## 2. Framing
```
[ 0x4C 0x4D "LM" ][ flags: uint16 BE ][ length: uint32 BE ][ payload: length bytes ]
```
- `flags = 0x0001`: the payload is a UTF-8 JSON object with a `"type"` field. Other flag values are reserved and ignored.
- `length` is 1 byte to 16 MB. Both sides drop the connection on a bad magic or an oversized length.

## 3. Pairing and authentication
On connect the **phone speaks first**:
```json
{"type":"AUTH_CHALLENGE","phoneId":"<uuid>","phoneName":"vivo I1928","nonce":"<32 hex>"}
```
Until authentication completes, the phone ignores every frame except `PAIRING_HANDSHAKE`. The Mac ignores everything except `AUTH_CHALLENGE` and `PAIRING_ACK`.

**Mac → phone, already paired** (secret `S` stored for `phoneId`):
```json
{"type":"PAIRING_HANDSHAKE","deviceId":"<mac uuid>","deviceName":"…","platform":"macos",
 "macNonce":"<32 hex>","proof":"hex(HMAC-SHA256(S, \"mac|\" + nonce))"}
```
**Mac → phone, first pairing** (code from the phone's screen or its QR):
```json
{"type":"PAIRING_HANDSHAKE","deviceId":"…","deviceName":"…","platform":"macos","macNonce":"…",
 "pairingCode":"ABC123","macPublicKey":"<base64 DER SubjectPublicKeyInfo, ephemeral P-256>"}
```
**Phone → Mac:**
```json
{"type":"PAIRING_ACK","accepted":true,"deviceName":"…",
 "proof":"hex(HMAC-SHA256(S, \"phone|\" + macNonce))",
 "phonePublicKey":"<base64 DER SPKI, first pairing only>"}
{"type":"PAIRING_ACK","accepted":false,"error":"PAIRING_REQUIRED | INVALID_CODE | RATE_LIMITED"}
```
- On first pairing, `S = HMAC-SHA256(ECDH-P256 shared x-coordinate, "linkmymac-pairing-v1")`, derived on both sides. `S` itself never crosses the wire.
- The Mac only trusts the phone after checking its `proof`. A failed proof from a known phone means the phone forgot this Mac, so the Mac drops `S` and asks for a code.
- Codes are 6 characters from `A–Z 2–9` without `0 O 1 I L`, and each is single-use. A wrong code blocks all code attempts for 3 s.
- The phone closes sockets that stay unauthenticated and silent for 30 s, and accepts at most 8 sockets at once.
- The phone stores `S` per Mac `deviceId` in SharedPreferences ("Forget Paired Macs" clears them). The Mac stores `S` per `phoneId` in UserDefaults.
- A paired Mac can send `{"type":"UNPAIR"}` to remove only itself; the phone deletes its `S` and closes the session.

## 4. File transfer (either direction)
```
sender   → FILE_OFFER             {transferId, fileName, mimeType, totalBytes (-1 if unknown)}
sender   → FILE_CHUNK             {transferId, chunkIndex 0…n, dataBase64 (≤ 64 KB raw)}
sender   → FILE_TRANSFER_COMPLETE {transferId, totalChunks}
receiver → FILE_TRANSFER_RESULT   {transferId, ok, error?}
```
- Receivers reject out-of-order chunks and a chunk-count mismatch. Partial files are deleted.
- Senders wait for the socket to take each chunk (backpressure), so any file size streams in constant memory.
- The phone saves to `Download/LinkMyMac` through MediaStore. The Mac saves to `~/Downloads` and never overwrites (`name (1).ext`). Both sides reduce incoming names to a plain file name.
- Gallery downloads reuse this: the Mac sends `MEDIA_DOWNLOAD_REQUEST {mediaId, transferId: "media_<id>"}`, and the phone answers with the frames above and the name `media_<id>.<ext>`.

## 5. Other messages (JSON `type`)
| Direction | Types |
|:---|:---|
| Mac → phone | `HEARTBEAT_PING` (every 5 s), `NOTIFICATIONS_SYNC_REQUEST`, `NOTIFICATION_ACTION`, `NOTIFICATION_DISMISS`, `NOTIFICATION_CLEAR_ALL`, `CLIPBOARD_EVENT`, `MEDIA_INDEX_REQUEST`, `MEDIA_DOWNLOAD_REQUEST`, `MEDIA_DELETE_REQUEST`, `CAMERA_CONTROL`, `NOW_PLAYING_UPDATE`, `UNPAIR` |
| Phone → Mac | `HEARTBEAT_PONG` (battery %), `NOTIFICATION_EVENT`, `CLIPBOARD_EVENT`, `MEDIA_INDEX_RESPONSE`, `MEDIA_GALLERY_UPDATED`, `MEDIA_DELETE_RESPONSE`, `CAMERA_FRAME`, `CAMERA_STREAM_STATUS`, `MEDIA_CONTROL_COMMAND` |

**Gallery paging.** `MEDIA_INDEX_REQUEST {offset, limit, includeThumbnails, mediaType}` takes `mediaType` `"image"` or `"video"` so photos and videos page independently, newest first. Leaving it out pages both together. The response echoes `mediaType`, and its `totalCount` covers that type only. Videos include `durationMs`.

## 6. Not implemented yet
- **TLS.** The QR payload already carries the phone's certificate fingerprint (`certFp`) for pinning, but the sockets don't use it. Until then, Wi-Fi traffic is readable by others on the network, and an active attacker could hijack a session. USB traffic stays off the network.
- **Binary frames** (`flags 0x0002`) and **Protobuf.** Files travel as base64 inside JSON, which costs about 33% in size.
