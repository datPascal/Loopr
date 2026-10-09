# Contributing to Loopr

Loopr welcomes focused bug fixes, tests, documentation, and small features. Open an issue before starting a large change so the scope and safety requirements are clear.

## Before submitting code

Use only material you have the right to share. Do not submit:

- WHOOP source code, firmware, binaries, logos, screenshots, product artwork, or confidential material;
- data scraped from WHOOP services;
- code copied from another reverse-engineering project unless its license permits reuse and the required notices are included;
- captures or fixtures containing health data, device identifiers, account details, location history, or credentials from a real person.

Protocol findings must come from hardware you own or are authorized to inspect. Describe how you observed the behavior and cite the public or testable source of each fact. Do not present guesses as protocol facts.

Changes to wellness metrics must cite the implemented method, expose an honest confidence level, and return no result when the inputs cannot support one. Loopr does not reproduce or claim equivalence with another product's algorithms or scores.

## Development setup

You need Xcode 26 or later and the iOS 26 SDK.

Run the Swift package tests:

```sh
swift test --package-path LooprPackages
```

Compile the app without signing:

```sh
xcodebuild build \
  -project Loopr/Loopr.xcodeproj \
  -scheme Loopr \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Hardware testing must use a band and data you are authorized to inspect. Redact serial numbers, Bluetooth identifiers, health records, location data, and account information before attaching logs or fixtures.

## Pull requests

Keep each pull request limited to one change. Include:

- the problem and the behavior after the change;
- the tests you ran;
- the hardware and firmware used, if the change depends on a physical device;
- source and license details for new protocol facts, algorithms, fonts, images, or dependencies;
- any privacy, data-loss, health-claim, or compatibility risk introduced by the change.

All checks must pass. Do not weaken, skip, or repeatedly retry a failing test to obtain a green result.

By submitting a contribution, you agree that it may be distributed under Loopr's MIT License. You also confirm that you have the right to submit it.

## Security reports

Do not open a public issue for a vulnerability. Follow [SECURITY.md](SECURITY.md).

