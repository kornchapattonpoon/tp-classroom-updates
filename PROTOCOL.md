# TP Classroom protocol (version 1)

The Mac apps (Swift) and the Windows app (C#) both follow this spec, so any
teacher can work with any student. If you change one side, change the other.

## Ports

| Port | Protocol | Who listens | Used for |
|---|---|---|---|
| 52800 | TCP | student | encrypted teacher ↔ student connection |
| 52801 | UDP | teacher and student | automatic discovery (no IP addresses to type) |

## Class key

```
code      = trim(classCode).toUpperCase()
classKey  = PBKDF2-HMAC-SHA256(password = UTF8(code), salt = UTF8("TPClassroom/v1/class"),
                               iterations = 50000, length = 32 bytes)
classTag  = lowercase hex of the first 8 bytes of HMAC-SHA256(key = classKey, data = UTF8("TPClassroom/v1/beacon"))
```

## Discovery (UDP 52801, UTF-8 JSON, one object per datagram)

Students broadcast every 3 seconds, and immediately after a matching probe:

```json
{"tpc":1,"kind":"student","class":"<classTag>","id":"mac-…|win-…","name":"iMac-07",
 "user":"Somchai","os":"mac|windows","version":"1.0.0","port":52800}
```

Teachers broadcast a probe on start and every 10 seconds:

```json
{"tpc":1,"kind":"probe","class":"<classTag>"}
```

Datagrams are sent to every interface's directed broadcast address and to 255.255.255.255.
Anything with a different `class` is ignored, so classrooms on the same network stay separate.
The teacher learns each student's IP address from where its beacon came from.

## TCP handshake

1. Teacher → student: `"TPC1"` + 32 random bytes (`teacherNonce`)
2. Student → teacher: `"TPC1"` + 32 random bytes (`studentNonce`)
3. Both sides derive:
   ```
   salt = teacherNonce || studentNonce
   t2s  = HKDF-SHA256(ikm = classKey, salt, info = UTF8("TPClassroom/v1/t2s"), 32 bytes)   teacher → student
   s2t  = HKDF-SHA256(ikm = classKey, salt, info = UTF8("TPClassroom/v1/s2t"), 32 bytes)   student → teacher
   ```

## Records

After the handshake every record is:

```
[4-byte big-endian length N][N bytes = AES-256-GCM ciphertext || 16-byte tag]
nonce     = 4 zero bytes || 8-byte big-endian counter (starts at 0, +1 per record, separate per direction)
plaintext = [1 byte type][payload]
```

| Type | Payload |
|---|---|
| 1 | JSON message (UTF-8) |
| 2 | JPEG screen frame |
| 3 | update chunk (raw bytes) |

If a record fails to decrypt, the class codes don't match. Close the connection.
Maximum N is 16 MiB.

The teacher's first message is `hello`. The student's first message is `info`.

## Messages (JSON, camelCase, missing fields = null)

Every message has `"type"`.

Teacher → student:

| type | fields |
|---|---|
| `hello` | `name`, `version`, `os` |
| `stream` | `fps`, `maxWidth`, `quality` (0…1), `live` |
| `stopStream` | |
| `control` | `enabled` |
| `input` | `input` (see below) |
| `lock` | `text` |
| `unlock` | |
| `message` | `text` |
| `openUrl` | `url` (http/https only) |
| `typeText` | `text`: typed exactly as written, any keyboard language (only while `control` is on) |
| `power` | `action`: `shutdown` or `restart`. The student shows a 15-second warning first |
| `updateBegin` | `platform` (`mac`/`windows`), `version`, `size`, `sha256`, `signature` |
| `updateEnd` | |

Student → teacher:

| type | fields |
|---|---|
| `info` | `id`, `name`, `user`, `computer`, `os`, `version`, `screenOk`, `controlOk`, `locked` |
| `notice` | `text` |

### Input

```json
{"kind":"move|down|up|drag|scroll|key", "x":0.5, "y":0.5, "button":0, "clicks":1,
 "dx":0, "dy":-40, "code":"KeyA", "down":true, "mods":10}
```

- `x`, `y`: 0…1 across the student's main display, top-left = 0,0
- `button`: 0 left, 1 right, 2 middle
- `dx`, `dy`: scroll in pixels; positive `dy` = scroll up (one mouse-wheel notch ≈ 40)
- `code`: W3C `KeyboardEvent.code` name (`KeyA`, `Digit1`, `Enter`, `ShiftLeft`, `MetaLeft`, `ArrowUp`…)
- `mods`: 1 shift, 2 control, 4 alt/option, 8 meta (⌘/⊞), 16 caps lock
- If the teacher and student run different operating systems, the student swaps Meta and Control,
  so ⌘C from a Mac teacher becomes Ctrl+C on Windows, and the other way round.

## Updates

All packages are signed with one ECDSA P-256 key (SHA-256). Signatures are 64 bytes `r||s`, in base64.
The public key is base64 DER SubjectPublicKeyInfo and is built into every app.

Students never download updates themselves. The teacher pushes its own version over the local
network (`updateBegin`, type-3 chunks of 512 KiB, `updateEnd`) to any student that is older, so
teacher and students always run the same version, even offline.

| platform | payload |
|---|---|
| `mac` | zip containing `TP Classroom Student.app` |
| `windows` | `TPClassroom.exe` itself (without the signature trailer) |

The Windows program keeps its own signature at the end of the file, so the single
`TP-Classroom-Setup-x.y.z.exe` can be passed on and checked later:

```
[exe bytes][signature JSON][8-byte little-endian JSON length]["TPCSIG01"]
signature JSON = {"platform":"windows","version":…,"sha256":…,"signature":…,"size":…}   (covers the exe bytes only)
```

Teachers update themselves from the feed (`appcast.json`):

```json
{"version":"1.0.1","notes":"…","publishedAt":"…","minimumMacOS":"13.0",
 "assets":{"mac-teacher":{"url":"…","sha256":"…","signature":"…","size":123},
           "windows":{"url":"…","sha256":"…","signature":"…","size":456}}}
```

The `windows` asset is the setup exe (with its signature trailer). The `mac-teacher` asset is a zip of `TP Classroom.app`.

## Test values

Use these to check that an implementation matches (class code `" room204 "`, normalized to `ROOM204`):

```
classKey  89557858551ea0e70303c6de4e80c211bee9ce2771a107e889c157b9d1f15897
classTag  251842b51b7db6b5
teacherNonce = bytes 0x00…0x1f, studentNonce = bytes 0x20…0x3f
t2s       0823161f46725d1d00b86afb967d4feaf45fc162611861f26dfba6527eff80ce
s2t       f9dd7af269ae8288461eeb2338fb5899d74b6fe16124fc5db55d54ca92282cc2
first teacher record (counter 0), plaintext 0x01 + {"type":"hello"}:
          2f39b8968bd8b9f27f297210ce1f73d208f70fc6e689dc352609864b4152a0581a
```
