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
- Multi-select on the Mac sends one `MEDIA_DOWNLOAD_REQUEST` or `MEDIA_DELETE_REQUEST` per item. The phone streams gallery downloads one at a time and coalesces the resulting MediaStore changes into a single `MEDIA_GALLERY_UPDATED` (500 ms debounce).

## 4b. Video streaming (byte ranges)
```
mac   → MEDIA_RANGE_REQUEST {requestId, mediaId, offset, length}
phone → MEDIA_RANGE_DATA    {requestId, offset, dataBase64 (≤ 256 KB raw)}   in order, repeated
phone → MEDIA_RANGE_DONE    {requestId, error?}
mac   → MEDIA_RANGE_CANCEL  {requestId}
```
- The Mac's AVPlayer issues these through an `AVAssetResourceLoaderDelegate`, so playback starts after the first few hundred KB instead of after a full download. Seeking is just another range.
- Phone recordings keep the MP4 index at the end of the file. AVPlayer fetches it first with a tail range, then streams from the start.
- The phone reads with blocking writes (paced by the link) and checks for `MEDIA_RANGE_CANCEL` between chunks. The Mac cancels on seek and when the player closes; a dropped connection ends every open range with an error.

## 4c. Phone features (SMS, calls, mirroring, control, hotspot)
| Mac → phone | Phone → Mac | Notes |
|:---|:---|:---|
| `SMS_THREADS_REQUEST {limit}` | `SMS_THREADS {threads: [{threadId, address, name, snippet, dateMs, unread}]}` or `{error}` | `READ_SMS`; names need `READ_CONTACTS` |
| `SMS_MESSAGES_REQUEST {threadId, limit}` | `SMS_MESSAGES {threadId, messages: [{id, body, dateMs, incoming}]}` | Oldest first |
| `SMS_SEND {requestId, address, body}` | `SMS_SEND_RESULT {requestId, ok, error?}` | `SEND_SMS`; long text goes as multipart |
| (none) | `SMS_UPDATED` | Sent when anything changes in the SMS store (debounced 0.5 s) |
| `CALL_ACTION {action: answer, decline or end}`, `CALL_DIAL {number}` | `CALL_ACTION_RESULT {ok, error?}` | `ANSWER_PHONE_CALLS`, `CALL_PHONE` |
| `CALL_LOG_REQUEST {limit}` | `CALL_LOG {calls: [{number, name, kind, dateMs, durationSec}]}` or `{error}` | `READ_CALL_LOG` |
| (none) | `CALL_STATE {state: ringing, active or idle; number; name}` | `READ_PHONE_STATE` (`READ_CALL_LOG` adds the number). Call audio stays on the phone. |
| `MIRROR_START`, `MIRROR_STOP` | `MIRROR_STATUS {active, width, height, controlEnabled, error?}`, `MIRROR_FRAME {width, height, jpegBase64}` | The person approves Android's capture prompt each session. Up to 720 px wide and ~12 fps; when the link is slow, frames are dropped, not queued. |
| `INPUT_TAP {x, y, durationMs}`, `INPUT_SWIPE {x1, y1, x2, y2, durationMs}`, `INPUT_TEXT {text}`, `INPUT_KEY {key: backspace or enter}`, `INPUT_GLOBAL {action: back, home, recents or notifications}` | `CONTROL_STATUS {enabled: false}` while Mac Control is off | Positions are 0–1 of the screen. Needs the "LinkMyMac Mac Control" accessibility service. |
| `HOTSPOT_REQUEST` | `HOTSPOT_RESULT {prompted}` | Apps can't switch tethering on, so the phone shows a one-tap notification that opens Hotspot settings |

`HEARTBEAT_PONG` also carries `network` (`5G`, `4G`, …) and `signalLevel` (0–4, or -1 when unknown).

## 5. Other messages (JSON `type`)
| Direction | Types |
|:---|:---|
| Mac → phone | `HEARTBEAT_PING` (every 5 s), `NOTIFICATIONS_SYNC_REQUEST`, `NOTIFICATION_ACTION`, `NOTIFICATION_DISMISS`, `NOTIFICATION_CLEAR_ALL`, `CLIPBOARD_EVENT`, `MEDIA_INDEX_REQUEST`, `MEDIA_DOWNLOAD_REQUEST`, `MEDIA_DELETE_REQUEST`, `CAMERA_CONTROL`, `NOW_PLAYING_UPDATE`, `UNPAIR`, `MEDIA_RANGE_REQUEST`, `MEDIA_RANGE_CANCEL`, `VOLUME_STATE` (`volume` 0–100, `muted`; on connect and on change) |
| Phone → Mac | `HEARTBEAT_PONG` (battery %), `NOTIFICATION_EVENT`, `CLIPBOARD_EVENT`, `MEDIA_INDEX_RESPONSE`, `MEDIA_GALLERY_UPDATED`, `MEDIA_DELETE_RESPONSE`, `CAMERA_FRAME`, `CAMERA_STREAM_STATUS`, `MEDIA_CONTROL_COMMAND` (`action`: `TOGGLE_PLAY_PAUSE`, `NEXT_TRACK`, `PREV_TRACK`, `VOLUME_UP`, `VOLUME_DOWN`, `VOLUME_MUTE`, `SET_VOLUME:<0-100>`), `MEDIA_RANGE_DATA`, `MEDIA_RANGE_DONE` |

**Gallery paging.** `MEDIA_INDEX_REQUEST {offset, limit, includeThumbnails, mediaType}` takes `mediaType` `"image"` or `"video"` so photos and videos page independently, newest first. Leaving it out pages both together. The response echoes `mediaType`, and its `totalCount` covers that type only. Videos include `durationMs`. Every item carries `bucket` (its folder, e.g. `Camera`) and `relativePath` (e.g. `DCIM/Camera/`), which the Mac uses for Group by Folder.

## 6. Not implemented yet
- **TLS.** The QR payload already carries the phone's certificate fingerprint (`certFp`) for pinning, but the sockets don't use it. Until then, Wi-Fi traffic is readable by others on the network, and an active attacker could hijack a session. USB traffic stays off the network.
- **Binary frames** (`flags 0x0002`) and **Protobuf.** Files travel as base64 inside JSON, which costs about 33% in size.
