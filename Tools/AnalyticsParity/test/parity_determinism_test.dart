import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String _packageRoot() {
  var directory = Directory.current;
  while (true) {
    if (File('${directory.path}/bin/parity_runner.dart').existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('unable to locate Tools/AnalyticsParity package root');
    }
    directory = parent;
  }
}

Map<String, dynamic> _sleepFixture({
  required String? timeZoneIdentifier,
  required int startTimestamp,
  required int sampleCount,
}) {
  final fixture = <String, dynamic>{
    'metric': 'sleepSegmentation',
    'acceleration': [
      for (var index = 0; index < sampleCount; index++)
        {
          'timestamp': startTimestamp + index,
          'x': 0.0,
          'y': 0.0,
          'z': 1.0,
          'valid': true,
        },
    ],
    'heart_rate': [
      for (var index = 0; index < sampleCount; index++)
        {
          'timestamp': startTimestamp + index,
          'bpm': 55.0,
          'valid': true,
        },
    ],
    'rr': const <Map<String, Object?>>[],
  };
  if (timeZoneIdentifier != null) {
    fixture['time_zone_identifier'] = timeZoneIdentifier;
  }
  return fixture;
}

File _writeFixture(
    Directory directory, String name, Map<String, dynamic> fixture) {
  return File('${directory.path}/$name.json')
    ..writeAsStringSync(jsonEncode(fixture));
}

ProcessResult _runDartRunner({
  required String packageRoot,
  required File fixture,
  required String hostTimeZone,
}) {
  final environment = Map<String, String>.from(Platform.environment)
    ..['TZ'] = hostTimeZone;
  return Process.runSync(
    Platform.resolvedExecutable,
    <String>['run', '$packageRoot/bin/parity_runner.dart', fixture.path],
    workingDirectory: packageRoot,
    environment: environment,
  );
}

void main() {
  late String packageRoot;
  late Directory temporaryDirectory;

  setUpAll(() {
    packageRoot = _packageRoot();
  });

  setUp(() {
    temporaryDirectory =
        Directory.systemTemp.createTempSync('loopr-parity-determinism-');
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  group('ParityDeterminismTests', () {
    test('Dart runner rejects a missing IANA timezone declaration', () {
      final fixture = _writeFixture(
        temporaryDirectory,
        'missing-timezone',
        _sleepFixture(
          timeZoneIdentifier: null,
          startTimestamp: 0,
          sampleCount: 0,
        ),
      );
      final result = _runDartRunner(
        packageRoot: packageRoot,
        fixture: fixture,
        hostTimeZone: 'UTC',
      );

      expect(result.exitCode, isNonZero);
      expect(result.stderr.toString(), contains('FormatException'));
      expect(result.stderr.toString(), contains('time_zone_identifier'));
    });

    test('Dart runner rejects an unresolvable IANA timezone identifier', () {
      final fixture = _writeFixture(
        temporaryDirectory,
        'unknown-timezone',
        _sleepFixture(
          timeZoneIdentifier: 'Mars/Olympus_Mons',
          startTimestamp: 0,
          sampleCount: 0,
        ),
      );
      final result = _runDartRunner(
        packageRoot: packageRoot,
        fixture: fixture,
        hostTimeZone: 'UTC',
      );

      expect(result.exitCode, isNonZero);
      expect(result.stderr.toString(), contains('FormatException'));
      expect(result.stderr.toString(), contains('unresolvable'));
    });

    test('sleepSegmentation bytes do not depend on the host timezone', () {
      // The DST fixture spans the 2024-03-10 America/New_York spring-forward
      // transition (05:00–08:20 UTC).  It is long enough to exercise the auto
      // segmentation path and the timestamp resolver on both sides of the
      // transition, while the UTC fixture proves the fixed-zone path too.
      final utcFixture = _writeFixture(
        temporaryDirectory,
        'explicit-utc',
        _sleepFixture(
          timeZoneIdentifier: 'UTC',
          startTimestamp: 1710032400,
          sampleCount: 12000,
        ),
      );
      final dstFixture = _writeFixture(
        temporaryDirectory,
        'explicit-new-york',
        _sleepFixture(
          timeZoneIdentifier: 'America/New_York',
          startTimestamp: 1710046800,
          sampleCount: 12000,
        ),
      );

      final utcOutputs = <String>[];
      final dstOutputs = <String>[];
      for (final hostTimeZone in <String>['UTC', 'Asia/Bangkok']) {
        final utcResult = _runDartRunner(
          packageRoot: packageRoot,
          fixture: utcFixture,
          hostTimeZone: hostTimeZone,
        );
        final dstResult = _runDartRunner(
          packageRoot: packageRoot,
          fixture: dstFixture,
          hostTimeZone: hostTimeZone,
        );
        expect(utcResult.exitCode, 0, reason: utcResult.stderr.toString());
        expect(dstResult.exitCode, 0, reason: dstResult.stderr.toString());
        utcOutputs.add(utcResult.stdout.toString());
        dstOutputs.add(dstResult.stdout.toString());
      }

      expect(utcOutputs[1], equals(utcOutputs[0]));
      expect(dstOutputs[1], equals(dstOutputs[0]));
      final dstJson = jsonDecode(dstOutputs[0]) as Map<String, dynamic>;
      expect(dstJson['present'], isTrue, reason: dstOutputs[0]);
    });

    test('post-2038 New York POSIX rules stay host-timezone independent', () {
      // 2040-03-11 13:20–16:40 UTC crosses the second-Sunday spring-forward
      // rule after the explicit TZif transition table has ended.  The local
      // midpoint is 11:00 with DST (-04:00), inside the daytime guard; a
      // stale last-table offset (-05:00) would incorrectly place it at 10:00.
      final fixture = _writeFixture(
        temporaryDirectory,
        'post-2038-new-york',
        _sleepFixture(
          timeZoneIdentifier: 'America/New_York',
          startTimestamp: 2215084820,
          sampleCount: 12000,
        ),
      );
      final fixedZoneFixture = _writeFixture(
        temporaryDirectory,
        'post-2038-tokyo',
        _sleepFixture(
          timeZoneIdentifier: 'Asia/Tokyo',
          startTimestamp: 2215084800,
          sampleCount: 12000,
        ),
      );
      final outputs = <String>[];
      final fixedZoneOutputs = <String>[];
      for (final hostTimeZone in <String>['UTC', 'Asia/Bangkok']) {
        final result = _runDartRunner(
          packageRoot: packageRoot,
          fixture: fixture,
          hostTimeZone: hostTimeZone,
        );
        final fixedZoneResult = _runDartRunner(
          packageRoot: packageRoot,
          fixture: fixedZoneFixture,
          hostTimeZone: hostTimeZone,
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(fixedZoneResult.exitCode, 0,
            reason: fixedZoneResult.stderr.toString());
        outputs.add(result.stdout.toString());
        fixedZoneOutputs.add(fixedZoneResult.stdout.toString());
      }
      expect(outputs[1], equals(outputs[0]));
      expect(fixedZoneOutputs[1], equals(fixedZoneOutputs[0]));
      final json = jsonDecode(outputs[0]) as Map<String, dynamic>;
      expect(json['present'], isFalse, reason: outputs[0]);
    });
  });
}
