# Security policy

## Supported versions

Loopr is pre-release software. Security fixes go to the `main` branch and ship in the next TestFlight build.

| Version | Supported |
| --- | --- |
| Current `main` branch | Yes |
| Latest TestFlight build | Yes |
| Old commits and unofficial builds | No |

## Report a vulnerability privately

Do not open a public issue. Use [GitHub's private vulnerability reporting page](https://github.com/datPascal/Loopr/security/advisories/new). If that page doesn't work, email pascallindenau@googlemail.com and leave out sensitive details until we agree on a private channel.

Never include health records, location history, Bluetooth identifiers, account details, API keys, or another person's data in an initial report. Use synthetic data whenever possible.

A useful report includes the affected commit, impact, reproduction steps, and a minimal proof of concept. Allow up to seven days for an initial response. Loopr has no bug-bounty program.

## In scope

- disclosure or corruption of locally stored health, journal, cycle, workout, or route data;
- network transmission the user did not initiate and approve;
- exposure or mishandling of an AI provider credential;
- Bluetooth behavior that permits unauthorized control, unsafe writes, or data loss;
- failures in export, backup, restore, or deletion that expose private data;
- dependency or build-pipeline vulnerabilities that affect Loopr users or contributors.

## Outside Loopr's scope

Report vulnerabilities in WHOOP hardware, firmware, apps, accounts, servers, or services to WHOOP through its own security process. Do not send that material to Loopr or publish it here.

A disagreement between Loopr's wellness estimate and another product's score is normally a bug report, not a security vulnerability. Do not use public issues if the supporting material contains private health data.

## Disclosure

Give the maintainer time to investigate and release a fix before publishing technical details. Credit is available if requested, unless the report cannot be verified or the reporter asks to remain anonymous.

