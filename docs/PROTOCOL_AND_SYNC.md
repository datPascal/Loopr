# Protocol and Sync Safety

## Scope

This document captures the minimum verified WHOOP 4.0 transport behavior required for a safe native port. It is not a complete protocol specification. Unknown and empirical behavior must stay labeled as such.

## GATT Layout

| Role | UUID | Operation |
|---|---|---|
| Service | `61080001-8D6D-82B8-614A-1C8CB0F8DCC6` | Harvard service |
| Command to band | `61080002-8D6D-82B8-614A-1C8CB0F8DCC6` | Write with response |
| Command response | `61080003-8D6D-82B8-614A-1C8CB0F8DCC6` | Notify |
| Events | `61080004-8D6D-82B8-614A-1C8CB0F8DCC6` | Notify |
| Data | `61080005-8D6D-82B8-614A-1C8CB0F8DCC6` | Notify |

Persist `CBPeripheral.identifier` on iOS, not a MAC address.

## Setup Order

```text
provision with AccessorySetupKit when needed
-> create or restore the central manager
-> retrieve or scan for the peripheral
-> connect
-> discover service and required characteristics
-> subscribe to command-response, event, and data notifications
-> set the band clock
-> read the clock for drift correlation
-> initialize session cursors and policies
-> enter listening
-> send the initialization command sequence
```

All subscriptions must be active before commands that can trigger a response or data flood.

## Frame Envelope

```text
offset  size  field
0       1     0xAA start marker
1       2     declared length, UInt16 little-endian
3       1     CRC-8 of the two length bytes
4       N     inner packet padded to a four-byte boundary
4+N     4     CRC-32 of padded inner packet, little-endian
```

The declared length is the padded inner length plus four CRC bytes.

Reassembly requirements:

- Keep independent buffers for command-response, event, and data characteristics.
- Support one frame split across many notifications.
- Support multiple frames in one notification.
- Do not treat an embedded `0xAA` as a new frame after accepting a valid length.
- Reject impossible lengths and frames larger than the documented safety limit.
- Check length CRC before buffering the declared body.
- Validate payload CRC before dispatch.

## Packet Routing

Common packet types include:

| Value | Meaning | Route |
|---:|---|---|
| `0x24` | Command response | Immediate |
| `0x28` | Compact realtime HR/RR | Immediate, RAM-only |
| `0x2B` | Realtime raw record | Immediate, RAM-only |
| `0x2F` | Historical record | Serialized history queue |
| `0x30` | Event | Immediate |
| `0x31` | History metadata | Serialized history queue |
| `0x32` | Console/log | Immediate and accounted |
| `0x33` | Realtime IMU | Immediate, RAM-only |

All metadata must use the same serialized queue as historical records, even if it arrives on another characteristic. Otherwise a history-end marker can overtake records that have not yet been persisted.

## Initialization

The reference client sends five commands with fixed sequence values `0...4`:

| Seq | Opcode | Purpose |
|---:|---:|---|
| `0` | `0x23` | Hello |
| `1` | `0x4C` | Advertising name |
| `2` | `0x22` | Data range |
| `3` | `0x43` | Alarm time |
| `4` | `0x16` | Start historical data |

Exact byte vectors should be copied from the pinned protocol tests into Swift golden tests rather than recreated from this summary.

## Clock

The band clock must be set before history timestamps can be trusted. The set-clock payload contains Unix seconds, 32,768-Hz subsecond ticks, and two zero bytes.

Maintain a correlation between wall clock and strap clock for alarms. Clear it on every disconnect. Reject implausible clock values and cap correction attempts per connection.

## History Markers

Metadata subtype meanings:

- `1`: start;
- `2`: end of a tokenized chunk;
- `3`: complete.

The history-end marker contains an opaque eight-byte token. Treat the token as data, not as an integer. A projected batch ID may overlap its final bytes but does not replace the full token.

## Commit-Before-ACK

The history coordinator is the only component allowed to commit a token or send a history success ACK.

```swift
func handleEnd(_ end: HistoryEnd, session: SessionID) async {
    guard session == currentSession, !burst.isDiscarded else { return }

    let snapshot = burst.snapshot()

    do {
        try await store.commit(
            records: snapshot.records,
            archived: snapshot.archived,
            token: end.token
        )
    } catch {
        burst.restoreToFront(snapshot)
        return
    }

    guard session == currentSession, !burst.isDiscarded else { return }
    await writer.sendHistorySuccess(exactToken: end.token)
}
```

The real implementation also needs bounded ACK retry, reconnect on exhaustion, durable failure diagnostics, and cancellation handling.

## Failure Rules

- Failed database commit: restore the snapshot and do not ACK.
- Session replaced during commit: do not ACK from the old session.
- Burst timed out and was discarded: abort/retry and never ACK a late terminal marker.
- ACK write failed after commit: reconnect; duplicate redelivery is safe.
- Unsupported record: archive raw bytes in the same transaction, then it may be ACKed.
- History complete: commit any tail, do not ACK, remain listening.

## Live Streams

High-rate streams are enabled only while a feature needs them. They are RAM-only:

- compact HR/RR `0x28`;
- realtime raw `0x2B`;
- realtime IMU `0x33`.

When backgrounded without an active workout, spot check, calibration, or breathing session, downgrade to the lightest stream mode that still supports useful connection and HR behavior.

## Command Safety

The final write queue should use an allowlist for production commands. Never automatically expose or send force-trim, reboot, power-cycle, persistent raw mode, or firmware-loading opcodes.

Do not expose a generic arbitrary-opcode API in release builds.

## Required Golden Tests

1. CRC-8 and CRC-32 vectors.
2. Frame padding and declared length.
3. Fragmented and coalesced notifications.
4. Embedded `0xAA` in payload and token.
5. Corrupt length CRC resynchronization.
6. Exact five initialization frames.
7. Exact set-clock payload.
8. Exact history-end token extraction.
9. Exact success ACK with verbatim token.
10. Commit completion occurs before ACK write.
11. Commit failure blocks ACK and restores records.
12. Replaced session blocks stale ACK.
13. Discarded burst blocks late terminal ACK.
14. ACK exhaustion reconnects without losing committed data.
15. Unsupported records are archived before ACK.
16. High-rate packet types are never inserted into the historical store.
17. Dangerous commands cannot reach the final writer.
18. Restoration resumes with one CoreBluetooth owner.

## Non-Negotiable Invariants

1. Subscribe before initiating data-producing commands.
2. Serialize writes and use write-with-response.
3. Use one logical band owner.
4. Use one ordered queue for records and history metadata.
5. Commit records, archive, cursors, and exact token before ACK.
6. Never ACK a stale, failed, or discarded burst.
7. Preserve unknown records rather than silently discarding them.
8. Recreate session-scoped parsers, references, timers, and state on reconnect.
9. Keep live high-rate data out of durable historical storage.
10. Treat recent valid notifications as stronger evidence than a connected flag.
