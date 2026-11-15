#!/usr/bin/env python3
"""
End-to-end check of the phone's pairing gate and file receive path (WIRE_SPEC.md §3-4).

Plays the Mac's role against a real phone:
    adb forward tcp:8765 tcp:8765
    python3 protocol/e2e_check.py --code ABC123      # code shown in the Android app

Leaves one test "Mac" paired on the phone (use "Forget Paired Macs" to remove it).
Standard library only; the P-256 math below is test-grade (not constant time).
"""
import argparse, base64, hashlib, hmac, json, os, secrets, socket, struct, sys, time, uuid

# --- minimal P-256 ECDH -----------------------------------------------------------
P = 2**256 - 2**224 + 2**192 + 2**96 - 1
A = P - 3
G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
     0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")

def ec_add(p, q):
    if p is None: return q
    if q is None: return p
    if p[0] == q[0] and (p[1] + q[1]) % P == 0: return None
    if p == q: s = (3 * p[0] * p[0] + A) * pow(2 * p[1], -1, P) % P
    else: s = (q[1] - p[1]) * pow(q[0] - p[0], -1, P) % P
    x = (s * s - p[0] - q[0]) % P
    return x, (s * (p[0] - x) - p[1]) % P

def ec_mul(k, pt):
    acc = None
    while k:
        if k & 1: acc = ec_add(acc, pt)
        pt, k = ec_add(pt, pt), k >> 1
    return acc

def spki(pt): return SPKI_PREFIX + b"\x04" + pt[0].to_bytes(32, "big") + pt[1].to_bytes(32, "big")
def from_spki(der): return int.from_bytes(der[-64:-32], "big"), int.from_bytes(der[-32:], "big")

# --- framing: [ "LM" ][ flags 0x0001 ][ uint32 BE length ][ JSON ] ----------------
def send(sock, obj):
    payload = json.dumps(obj).encode()
    sock.sendall(b"LM\x00\x01" + struct.pack(">I", len(payload)) + payload)

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        part = sock.recv(n - len(buf))
        if not part: raise ConnectionError("phone closed the connection")
        buf += part
    return buf

def recv(sock, timeout):
    sock.settimeout(timeout)
    magic, _flags, length = struct.unpack(">HHI", recv_exact(sock, 8))
    assert magic == 0x4C4D, "bad frame magic"
    return json.loads(recv_exact(sock, length))

def recv_type(sock, wanted, timeout=5.0):
    """Skip unrelated frames (notifications etc.) until `wanted` arrives."""
    deadline = time.time() + timeout
    while True:
        msg = recv(sock, max(deadline - time.time(), 0.01))
        if msg.get("type") == wanted:
            return msg

def proof(secret, role, nonce):
    return hmac.new(secret, f"{role}|{nonce}".encode(), hashlib.sha256).hexdigest()

# --- the checks ----------------------------------------------------------------------
failures = 0
def check(name, ok, detail=""):
    global failures
    failures += 0 if ok else 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail and not ok else ""))

def connect(host, port):
    sock = socket.create_connection((host, port), timeout=5)
    return sock, recv_type(sock, "AUTH_CHALLENGE")

def handshake(device_id, mac_nonce, **extra):
    return {"type": "PAIRING_HANDSHAKE", "deviceId": device_id, "deviceName": "e2e-check",
            "platform": "macos", "macNonce": mac_nonce, **extra}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--code", required=True, help="pairing code shown on the phone")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    device_id = f"e2e-check-{uuid.uuid4()}"

    # 1. Unpaired connection: phone challenges, then ignores everything else.
    sock, ch = connect(args.host, args.port)
    check("phone sends AUTH_CHALLENGE first", bool(ch.get("nonce")) and bool(ch.get("phoneId")))
    for probe in ({"type": "HEARTBEAT_PING", "clientTimeMs": 1}, {"type": "NOTIFICATIONS_SYNC_REQUEST"},
                  {"type": "MEDIA_INDEX_REQUEST", "offset": 0, "limit": 5}):
        send(sock, probe)
    try:
        leaked = recv(sock, 2.5)
        check("unpaired client gets no data", False, f"received {leaked.get('type')}")
    except socket.timeout:
        check("unpaired client gets no data", True)

    # 2. Wrong code, then the 3 s cooldown also blocks the right one.
    send(sock, handshake(device_id, "n1", pairingCode="ZZZZZZ", macPublicKey=base64.b64encode(spki(G)).decode()))
    ack = recv_type(sock, "PAIRING_ACK")
    check("wrong code rejected", ack.get("accepted") is False and ack.get("error") == "INVALID_CODE", str(ack))
    send(sock, handshake(device_id, "n2", pairingCode=args.code, macPublicKey=base64.b64encode(spki(G)).decode()))
    ack = recv_type(sock, "PAIRING_ACK")
    check("retry within cooldown is rate-limited", ack.get("error") == "RATE_LIMITED", str(ack))
    time.sleep(3.2)

    # 3. Right code + ECDH → both sides derive the same secret; phone proves it.
    priv = secrets.randbelow(N - 1) + 1
    mac_nonce = secrets.token_hex(16)
    send(sock, handshake(device_id, mac_nonce, pairingCode=args.code,
                         macPublicKey=base64.b64encode(spki(ec_mul(priv, G))).decode()))
    ack = recv_type(sock, "PAIRING_ACK")
    check("correct code accepted", ack.get("accepted") is True, str(ack))
    if not ack.get("accepted"):
        sys.exit(1)
    shared = ec_mul(priv, from_spki(base64.b64decode(ack["phonePublicKey"])))[0].to_bytes(32, "big")
    secret = hmac.new(shared, b"linkmymac-pairing-v1", hashlib.sha256).digest()
    check("phone proves the derived secret", ack.get("proof") == proof(secret, "phone", mac_nonce))
    check("secret itself never sent", "secret" not in ack)

    send(sock, {"type": "HEARTBEAT_PING", "clientTimeMs": 42})
    pong = recv_type(sock, "HEARTBEAT_PONG")
    check("paired client gets data", pong.get("clientTimeMs") == 42)

    # Gallery lists photos and videos; the smallest video streams intact (with backpressure).
    send(sock, {"type": "MEDIA_INDEX_REQUEST", "offset": 0, "limit": 1000, "includeThumbnails": False})
    items = recv_type(sock, "MEDIA_INDEX_RESPONSE", timeout=30)["items"]
    videos = [i for i in items if i.get("mimeType", "").startswith("video/")]
    print(f"      gallery page: {len(items) - len(videos)} photos, {len(videos)} videos")
    if videos:
        video = min(videos, key=lambda v: int(v["sizeBytes"]))
        check("videos carry a duration", int(video.get("durationMs", 0)) > 0, str(video))
        tid = f"media_{video['mediaId']}"
        started = time.time()
        send(sock, {"type": "MEDIA_DOWNLOAD_REQUEST", "mediaId": int(video["mediaId"]), "transferId": tid})
        digest, size, chunks = hashlib.md5(), 0, 0
        while True:
            msg = recv(sock, 30)
            if msg.get("transferId") != tid:
                continue
            if msg["type"] == "FILE_CHUNK":
                assert msg["chunkIndex"] == chunks, "chunk out of order"
                part = base64.b64decode(msg["dataBase64"])
                digest.update(part); size += len(part); chunks += 1
            elif msg["type"] == "FILE_TRANSFER_COMPLETE":
                break
        secs = max(time.time() - started, 0.001)
        check("video streams intact", size == int(video["sizeBytes"]) and msg["totalChunks"] == chunks,
              f"{size} vs {video['sizeBytes']}")
        print(f"      {video['displayName']} (id {video['mediaId']}): {size / 1e6:.1f} MB in {secs:.1f}s "
              f"({size / 1e6 / secs:.1f} MB/s) md5={digest.hexdigest()}")

    # 4. Mac → phone file transfer (lands in Download/LinkMyMac).
    data = os.urandom(200_000)
    name = f"linkmymac-e2e-{int(time.time())}.bin"
    tid = str(uuid.uuid4())
    send(sock, {"type": "FILE_OFFER", "transferId": tid, "fileName": name,
                "mimeType": "application/octet-stream", "totalBytes": len(data)})
    chunks = [data[i:i + 65536] for i in range(0, len(data), 65536)]
    for i, c in enumerate(chunks):
        send(sock, {"type": "FILE_CHUNK", "transferId": tid, "chunkIndex": i,
                    "dataBase64": base64.b64encode(c).decode()})
    send(sock, {"type": "FILE_TRANSFER_COMPLETE", "transferId": tid, "totalChunks": len(chunks)})
    res = recv_type(sock, "FILE_TRANSFER_RESULT", timeout=15)
    check("file saved on phone", res.get("ok") is True, str(res))
    print(f"      sent {name}  md5={hashlib.md5(data).hexdigest()}")
    old_nonce = ch["nonce"]
    sock.close()

    # 5. Reconnect with HMAC proof: no code, no secret on the wire.
    sock, ch = connect(args.host, args.port)
    mac_nonce = secrets.token_hex(16)
    send(sock, handshake(device_id, mac_nonce, proof=proof(secret, "mac", ch["nonce"])))
    ack = recv_type(sock, "PAIRING_ACK")
    check("reconnect with proof accepted", ack.get("accepted") is True and "phonePublicKey" not in ack, str(ack))
    check("phone proves itself on reconnect", ack.get("proof") == proof(secret, "phone", mac_nonce))
    sock.close()

    # 6. Replaying a proof from an earlier connection fails (fresh nonce each time).
    sock, ch = connect(args.host, args.port)
    send(sock, handshake(device_id, "n3", proof=proof(secret, "mac", old_nonce)))
    ack = recv_type(sock, "PAIRING_ACK")
    check("replayed proof rejected", ack.get("accepted") is False, str(ack))
    sock.close()

    print(f"\n{'ALL CHECKS PASSED' if failures == 0 else f'{failures} CHECK(S) FAILED'}")
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
