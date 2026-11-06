# Loopr protocols

A protocol is a file of rules and experiment designs. Loopr opens these files
from Files, the share sheet or a link. Each file holds rules and experiment
designs only, never anyone's health data. The format is documented in
[`docs/PROTOCOL_FILES.md`](../docs/PROTOCOL_FILES.md).

The five protocols here are the ones Loopr ships with:

| File | What it is |
|---|---|
| `gentle-start.looprprotocol` | A gentle start |
| `sleep-first.looprprotocol` | Sleep first |
| `fitness-for-the-long-run.looprprotocol` | Fitness for the long run |
| `everything-at-once.looprprotocol` | Everything at once |
| `start-empty.looprprotocol` | Start empty |

## Use one

Download a file on your iPhone and open it. Loopr shows what it would change
against your current protocol before it saves anything.

## Add yours

1. In Loopr, open Protocol, then Rules, then Share protocol, and save the file.
2. Open a pull request that adds the file to this folder, with one line for the
   table above.
3. Keep it to rules and experiment designs. Loopr leaves out your morning
   reasons and your numbers when it writes the file, so check nothing personal
   went into a rule's name.

Loopr checks every file it opens against the format. A file that fails the
check changes nothing.
