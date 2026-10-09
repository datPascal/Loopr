import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

String _usage() =>
    '''Usage: dart run Tools/AnalyticsParity/bin/parity_runner.dart [--help] FIXTURE.json

Runs one canonical analytics fixture through the pinned openstrap_analytics
package and emits one deterministic JSON object on stdout.''';

double _number(Object? value, String name) {
  if (value is num) return value.toDouble();
  throw FormatException('$name must be a number');
}

double? _optionalNumber(Object? value, String name) {
  if (value == null) return null;
  return _number(value, name);
}

List<double> _numbers(Object? value, String name) {
  if (value is! List) throw FormatException('$name must be an array');
  return value.map((v) => _number(v, name)).toList(growable: false);
}

List<double?> _nullableNumbers(Object? value, String name) {
  if (value is! List) throw FormatException('$name must be an array');
  return value
      .map((v) => v == null ? null : _number(v, name))
      .toList(growable: false);
}

List<bool>? _optionalBools(Object? value, String name) {
  if (value == null) return null;
  if (value is! List) throw FormatException('$name must be an array');
  return value.map((v) {
    if (v is bool) return v;
    throw FormatException('$name must contain booleans');
  }).toList(growable: false);
}

Map<String, dynamic> _metricJson(
    Metric<dynamic> metric, String algorithmVersion,
    [Object? Function(dynamic value)? encode]) {
  final result = Map<String, dynamic>.from(metric.toJson(encode));
  result['present'] = metric.present;
  result['algorithm_version'] = algorithmVersion;
  return result;
}

class _LocalDayBounds {
  final String localDay;
  final String timeZone;
  final int startMs;
  final int endMs;
  const _LocalDayBounds(this.localDay, this.timeZone, this.startMs, this.endMs);
  int get durationSeconds => ((endMs - startMs) / 1000).round();
}

int _firstSunday(int year, int month) {
  final first = DateTime.utc(year, month, 1);
  return 1 + ((7 - first.weekday) % 7);
}

int _offsetAtLocalMidnight(DateTime date, String timeZone) {
  if (timeZone == 'UTC' || timeZone == 'Etc/UTC') return 0;
  if (timeZone == 'Asia/Tokyo') return 9 * 60;
  if (timeZone == 'America/Los_Angeles' || timeZone == 'America/New_York') {
    final firstSundayMarch = _firstSunday(date.year, 3);
    final secondSundayMarch = firstSundayMarch + 7;
    final firstSundayNovember = _firstSunday(date.year, 11);
    final daylight = date.month > 3 && date.month < 11 ||
        date.month == 3 && date.day > secondSundayMarch ||
        date.month == 11 && date.day <= firstSundayNovember;
    if (timeZone == 'America/Los_Angeles') return daylight ? -7 * 60 : -8 * 60;
    return daylight ? -4 * 60 : -5 * 60;
  }
  final fixed =
      RegExp(r'^UTC([+-])(\d{2})(?::?(\d{2}))?$').firstMatch(timeZone);
  if (fixed != null) {
    final minutes =
        int.parse(fixed.group(2)!) * 60 + int.parse(fixed.group(3) ?? '0');
    return fixed.group(1) == '+' ? minutes : -minutes;
  }
  throw FormatException('unsupported parity time zone: $timeZone');
}

/// A small, read-only view of one IANA TZif zone.  Dart's [DateTime] API can
/// resolve the process' local zone, but it cannot ask for an arbitrary IANA
/// zone.  The parity runner must never use that process-local fallback, so it
/// reads the requested zoneinfo file explicitly and resolves the offset at
/// each fixture timestamp.
class _TzifHeader {
  final int version;
  final int ttisgmtcnt;
  final int ttisstdcnt;
  final int leapcnt;
  final int timecnt;
  final int typecnt;
  final int charcnt;

  const _TzifHeader({
    required this.version,
    required this.ttisgmtcnt,
    required this.ttisstdcnt,
    required this.leapcnt,
    required this.timecnt,
    required this.typecnt,
    required this.charcnt,
  });
}

class _PosixTransitionRule {
  // 0 = month.week.weekday, 1 = Julian day (1..365, ignoring Feb 29),
  // 2 = zero-based day of year (0..365, including Feb 29).
  final int kind;
  final int first;
  final int second;
  final int third;
  final int timeSeconds;

  const _PosixTransitionRule({
    required this.kind,
    required this.first,
    required this.second,
    required this.third,
    required this.timeSeconds,
  });

  int timestampSeconds(int year, int offsetBeforeSeconds) {
    final DateTime local;
    switch (kind) {
      case 0:
        final firstOfMonth = DateTime.utc(year, first, 1);
        final firstSunday = firstOfMonth.weekday % 7;
        var day = 1 + ((third - firstSunday + 7) % 7) + (second - 1) * 7;
        final daysInMonth = DateTime.utc(year, first + 1, 0).day;
        if (day > daysInMonth) day -= 7;
        local = DateTime.utc(year, first, day);
      case 1:
        var day = first - 1;
        if (_isLeapYear(year) && first >= 60) day += 1;
        local = DateTime.utc(year, 1, 1).add(Duration(days: day));
      case 2:
        local = DateTime.utc(year, 1, 1).add(Duration(days: first));
      default:
        throw const FormatException('unsupported POSIX TZ rule kind');
    }
    final localWithTime = local.add(Duration(seconds: timeSeconds));
    return localWithTime.millisecondsSinceEpoch ~/ 1000 - offsetBeforeSeconds;
  }
}

class _PosixRule {
  final int standardOffsetSeconds;
  final int daylightOffsetSeconds;
  final _PosixTransitionRule? start;
  final _PosixTransitionRule? end;

  const _PosixRule({
    required this.standardOffsetSeconds,
    required this.daylightOffsetSeconds,
    required this.start,
    required this.end,
  });

  int offsetAt(int timestampSeconds) {
    final startRule = start;
    final endRule = end;
    if (startRule == null || endRule == null) return standardOffsetSeconds;
    final year = DateTime.fromMillisecondsSinceEpoch(
      timestampSeconds * 1000,
      isUtc: true,
    ).year;
    final transitions = <({int timestamp, int offset})>[];
    for (var candidateYear = year - 2;
        candidateYear <= year + 2;
        candidateYear++) {
      transitions.add((
        timestamp:
            startRule.timestampSeconds(candidateYear, standardOffsetSeconds),
        offset: daylightOffsetSeconds,
      ));
      transitions.add((
        timestamp:
            endRule.timestampSeconds(candidateYear, daylightOffsetSeconds),
        offset: standardOffsetSeconds,
      ));
    }
    transitions.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    var offset = standardOffsetSeconds;
    for (final transition in transitions) {
      if (transition.timestamp > timestampSeconds) break;
      offset = transition.offset;
    }
    return offset;
  }
}

bool _isLeapYear(int year) =>
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

int _parsePosixOffset(String raw) {
  final match = RegExp(r'^([+-]?)(\d{1,3})(?::(\d{1,2})(?::(\d{1,2}))?)?$')
      .firstMatch(raw);
  if (match == null) throw FormatException('unsupported POSIX TZ offset: $raw');
  final hours = int.parse(match.group(2)!);
  final minutes = int.parse(match.group(3) ?? '0');
  final seconds = int.parse(match.group(4) ?? '0');
  if (minutes > 59 || seconds > 59 || hours > 24) {
    throw FormatException('unsupported POSIX TZ offset: $raw');
  }
  final magnitude = hours * 3600 + minutes * 60 + seconds;
  final sign = match.group(1) == '-' ? -1 : 1;
  // POSIX offsets are the number to add to local time to obtain UTC; the
  // analytics resolver exposes the opposite (seconds east of UTC).
  return -(sign * magnitude);
}

int _parsePosixTime(String raw) {
  final match = RegExp(r'^([+-]?)(\d{1,3})(?::(\d{1,2})(?::(\d{1,2}))?)?$')
      .firstMatch(raw);
  if (match == null)
    throw FormatException('unsupported POSIX TZ transition time: $raw');
  final hours = int.parse(match.group(2)!);
  final minutes = int.parse(match.group(3) ?? '0');
  final seconds = int.parse(match.group(4) ?? '0');
  if (minutes > 59 || seconds > 59 || hours > 167) {
    throw FormatException('unsupported POSIX TZ transition time: $raw');
  }
  final magnitude = hours * 3600 + minutes * 60 + seconds;
  return (match.group(1) == '-' ? -1 : 1) * magnitude;
}

_PosixTransitionRule _parsePosixTransitionRule(String raw) {
  final match = RegExp(
    r'^(M(\d{1,2})\.(\d)\.(\d)|J(\d{1,3})|(\d{1,3}))(?:/([+-]?\d{1,3}(?::\d{1,2}(?::\d{1,2})?)?))?$',
  ).firstMatch(raw);
  if (match == null)
    throw FormatException('unsupported POSIX TZ transition rule: $raw');
  final timeSeconds = _parsePosixTime(match.group(7) ?? '2');
  if (match.group(1)!.startsWith('M')) {
    final month = int.parse(match.group(2)!);
    final week = int.parse(match.group(3)!);
    final weekday = int.parse(match.group(4)!);
    if (month < 1 || month > 12 || week < 1 || week > 5 || weekday > 6) {
      throw FormatException('unsupported POSIX TZ transition rule: $raw');
    }
    return _PosixTransitionRule(
      kind: 0,
      first: month,
      second: week,
      third: weekday,
      timeSeconds: timeSeconds,
    );
  }
  if (match.group(5) != null) {
    final day = int.parse(match.group(5)!);
    if (day < 1 || day > 365) {
      throw FormatException('unsupported POSIX TZ transition rule: $raw');
    }
    return _PosixTransitionRule(
      kind: 1,
      first: day,
      second: 0,
      third: 0,
      timeSeconds: timeSeconds,
    );
  }
  final day = int.parse(match.group(1)!);
  if (day > 365)
    throw FormatException('unsupported POSIX TZ transition rule: $raw');
  return _PosixTransitionRule(
    kind: 2,
    first: day,
    second: 0,
    third: 0,
    timeSeconds: timeSeconds,
  );
}

_PosixRule? _parsePosixFooter(String? footer) {
  if (footer == null || footer.isEmpty) return null;
  final match = RegExp(
    r'^((?:[A-Za-z]{3,}|<[^>]+>))'
    r'([+-]?\d{1,3}(?::\d{1,2}(?::\d{1,2})?)?)'
    r'(?:((?:[A-Za-z]{3,}|<[^>]+>))'
    r'([+-]?\d{1,3}(?::\d{1,2}(?::\d{1,2})?)?)?)?'
    r'(?:,([^,]+),([^,]+))?$',
  ).firstMatch(footer);
  if (match == null)
    throw FormatException('unsupported POSIX TZ footer: $footer');
  final daylightName = match.group(3);
  final startRule = match.group(5);
  final endRule = match.group(6);
  if (daylightName == null) {
    if (startRule != null || endRule != null) {
      throw FormatException('unsupported POSIX TZ footer: $footer');
    }
    final standardOffset = _parsePosixOffset(match.group(2)!);
    return _PosixRule(
      standardOffsetSeconds: standardOffset,
      daylightOffsetSeconds: standardOffset,
      start: null,
      end: null,
    );
  }
  if (startRule == null || endRule == null) {
    throw FormatException('unsupported POSIX TZ footer: $footer');
  }
  final standardOffset = _parsePosixOffset(match.group(2)!);
  final daylightOffset = match.group(4) == null
      ? standardOffset + 3600
      : _parsePosixOffset(match.group(4)!);
  return _PosixRule(
    standardOffsetSeconds: standardOffset,
    daylightOffsetSeconds: daylightOffset,
    start: _parsePosixTransitionRule(startRule),
    end: _parsePosixTransitionRule(endRule),
  );
}

String? _tzifFooter(List<int> bytes, int blockEnd) {
  if (blockEnd >= bytes.length) return null;
  if (bytes[blockEnd] != 0x0A) {
    throw const FormatException('invalid IANA TZif footer delimiter');
  }
  final footerEnd = bytes.indexOf(0x0A, blockEnd + 1);
  if (footerEnd < 0 || footerEnd != bytes.length - 1) {
    throw const FormatException('truncated or unsupported IANA TZif footer');
  }
  if (footerEnd == blockEnd + 1) return null;
  final footerBytes = bytes.sublist(blockEnd + 1, footerEnd);
  if (footerBytes.any((byte) => byte < 0x20 || byte > 0x7E)) {
    throw const FormatException('non-ASCII IANA TZif footer');
  }
  return String.fromCharCodes(footerBytes);
}

class _TzifZone {
  final List<int> _transitionSeconds;
  final List<int> _transitionOffsets;
  final int _initialOffsetSeconds;
  final _PosixRule? _futureRule;

  const _TzifZone({
    required List<int> transitionSeconds,
    required List<int> transitionOffsets,
    required int initialOffsetSeconds,
    required _PosixRule? futureRule,
  })  : _transitionSeconds = transitionSeconds,
        _transitionOffsets = transitionOffsets,
        _initialOffsetSeconds = initialOffsetSeconds,
        _futureRule = futureRule;

  const _TzifZone.fixed(int offsetSeconds)
      : _transitionSeconds = const <int>[],
        _transitionOffsets = const <int>[],
        _initialOffsetSeconds = offsetSeconds,
        _futureRule = null;

  _TzifZone withFutureRule(_PosixRule? futureRule) => _TzifZone(
        transitionSeconds: _transitionSeconds,
        transitionOffsets: _transitionOffsets,
        initialOffsetSeconds: _initialOffsetSeconds,
        futureRule: futureRule,
      );

  int offsetAt(int timestampSeconds) {
    if (_transitionSeconds.isNotEmpty &&
        timestampSeconds < _transitionSeconds.first) {
      throw FormatException(
          'IANA time-zone data does not cover timestamp $timestampSeconds');
    }
    if (_transitionSeconds.isNotEmpty &&
        timestampSeconds > _transitionSeconds.last) {
      final futureRule = _futureRule;
      if (futureRule == null) {
        throw FormatException(
            'IANA time-zone data does not cover timestamp $timestampSeconds');
      }
      return futureRule.offsetAt(timestampSeconds);
    }
    var low = 0;
    var high = _transitionSeconds.length;
    // Upper-bound search: the last transition at or before the fixture time
    // determines the active type.  This remains deterministic across host
    // timezone settings because it only uses the parsed zone transitions.
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_transitionSeconds[middle] <= timestampSeconds) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final index = low - 1;
    return index < 0 ? _initialOffsetSeconds : _transitionOffsets[index];
  }
}

final _tzifCache = <String, _TzifZone>{};

const _zoneInfoRoots = <String>[
  '/usr/share/zoneinfo',
  '/var/db/timezone/zoneinfo',
  '/usr/share/lib/zoneinfo',
  '/etc/zoneinfo',
];

bool _isValidIanaIdentifier(String value) {
  if (value.isEmpty || value != value.trim() || value.contains('\u0000'))
    return false;
  if (value.startsWith('/') || value.endsWith('/') || value.contains('\\'))
    return false;
  final segment = RegExp(r'^[A-Za-z0-9._+\-]+$');
  return value.split('/').every((part) =>
      part.isNotEmpty && part != '.' && part != '..' && segment.hasMatch(part));
}

int _tzifUnsigned(List<int> bytes, int offset, int width) {
  if (offset < 0 || width <= 0 || offset + width > bytes.length) {
    throw const FormatException('truncated IANA TZif data');
  }
  var value = 0;
  for (var index = 0; index < width; index++) {
    value = (value << 8) | bytes[offset + index];
  }
  return value;
}

int _tzifSigned(List<int> bytes, int offset, int width) {
  final unsigned = _tzifUnsigned(bytes, offset, width);
  final sign = 1 << (width * 8 - 1);
  return unsigned & sign == 0 ? unsigned : unsigned - (1 << (width * 8));
}

_TzifHeader _tzifHeader(List<int> bytes, int offset) {
  if (offset < 0 ||
      offset + 44 > bytes.length ||
      bytes[offset] != 0x54 ||
      bytes[offset + 1] != 0x5A ||
      bytes[offset + 2] != 0x69 ||
      bytes[offset + 3] != 0x66) {
    throw const FormatException('invalid IANA TZif header');
  }
  final versionByte = bytes[offset + 4];
  if (versionByte != 0 &&
      versionByte != 0x32 &&
      versionByte != 0x33 &&
      versionByte != 0x34) {
    throw const FormatException('unsupported IANA TZif version');
  }
  return _TzifHeader(
    version: versionByte,
    ttisgmtcnt: _tzifUnsigned(bytes, offset + 20, 4),
    ttisstdcnt: _tzifUnsigned(bytes, offset + 24, 4),
    leapcnt: _tzifUnsigned(bytes, offset + 28, 4),
    timecnt: _tzifUnsigned(bytes, offset + 32, 4),
    typecnt: _tzifUnsigned(bytes, offset + 36, 4),
    charcnt: _tzifUnsigned(bytes, offset + 40, 4),
  );
}

int _tzifBlockLength(_TzifHeader header, int timeWidth) {
  return header.timecnt * timeWidth +
      header.timecnt +
      header.typecnt * 6 +
      header.charcnt +
      header.leapcnt * (timeWidth + 4) +
      header.ttisstdcnt +
      header.ttisgmtcnt;
}

_TzifZone _tzifBlock(
    List<int> bytes, int headerOffset, int timeWidth, _TzifHeader header) {
  final blockEnd = headerOffset + 44 + _tzifBlockLength(header, timeWidth);
  if (headerOffset < 0 || blockEnd > bytes.length) {
    throw const FormatException('truncated IANA TZif block');
  }
  var cursor = headerOffset + 44;
  final transitions = <int>[
    for (var index = 0; index < header.timecnt; index++)
      _tzifSigned(bytes, cursor + index * timeWidth, timeWidth),
  ];
  cursor += header.timecnt * timeWidth;
  final transitionTypes = <int>[
    for (var index = 0; index < header.timecnt; index++) bytes[cursor + index],
  ];
  cursor += header.timecnt;
  final offsets = <int>[];
  final daylight = <bool>[];
  for (var index = 0; index < header.typecnt; index++) {
    offsets.add(_tzifSigned(bytes, cursor, 4));
    daylight.add(bytes[cursor + 4] != 0);
    cursor += 6;
  }
  // Skip abbreviations, leap records, and standard/UTC indicators.  They do
  // not affect the offset lookup and are deliberately not exposed in output.
  cursor += header.charcnt +
      header.leapcnt * (timeWidth + 4) +
      header.ttisstdcnt +
      header.ttisgmtcnt;
  if (cursor > bytes.length || offsets.isEmpty)
    throw const FormatException('truncated IANA TZif block');

  var initialType = 0;
  for (var index = 0; index < daylight.length; index++) {
    if (!daylight[index]) {
      initialType = index;
      break;
    }
  }
  final transitionOffsets = <int>[];
  for (final type in transitionTypes) {
    if (type < 0 || type >= offsets.length)
      throw const FormatException('invalid IANA TZif transition type');
    transitionOffsets.add(offsets[type]);
  }
  return _TzifZone(
    transitionSeconds: List<int>.unmodifiable(transitions),
    transitionOffsets: List<int>.unmodifiable(transitionOffsets),
    initialOffsetSeconds: offsets[initialType],
    futureRule: null,
  );
}

_TzifZone _loadTzifZone(String identifier) {
  // Keep the UTC aliases usable even on a stripped-down runner without a
  // system zoneinfo directory.  They are fixed-offset IANA identifiers.
  if (identifier == 'UTC' ||
      identifier == 'Etc/UTC' ||
      identifier == 'Etc/GMT' ||
      identifier == 'GMT') {
    return const _TzifZone.fixed(0);
  }
  for (final root in _zoneInfoRoots) {
    final file = File('$root/$identifier');
    if (!file.existsSync()) continue;
    try {
      final bytes = file.readAsBytesSync();
      final first = _tzifHeader(bytes, 0);
      if (first.version == 0) return _tzifBlock(bytes, 0, 4, first);
      final secondOffset = 44 + _tzifBlockLength(first, 4);
      final second = _tzifHeader(bytes, secondOffset);
      final zone = _tzifBlock(bytes, secondOffset, 8, second);
      final secondBlockEnd = secondOffset + 44 + _tzifBlockLength(second, 8);
      return zone.withFutureRule(
        _parsePosixFooter(_tzifFooter(bytes, secondBlockEnd)),
      );
    } on FileSystemException {
      // Try the next standard zoneinfo root before reporting an unresolvable
      // identifier.  No process timezone is consulted as a fallback.
    }
  }
  throw FormatException('unresolvable IANA time_zone_identifier: $identifier');
}

_TzifZone _sleepTimeZone(Object? raw) {
  if (raw is! String || !_isValidIanaIdentifier(raw)) {
    throw const FormatException(
        'sleepSegmentation requires a declared IANA time_zone_identifier');
  }
  return _tzifCache.putIfAbsent(raw, () => _loadTzifZone(raw));
}

_LocalDayBounds _localDayBounds(String localDay, String timeZone) {
  final parts = localDay.split('-').map(int.parse).toList(growable: false);
  if (parts.length != 3)
    throw const FormatException('local_day must be YYYY-MM-DD');
  final localStart = DateTime.utc(parts[0], parts[1], parts[2]);
  final localEnd = localStart.add(const Duration(days: 1));
  final startOffset = _offsetAtLocalMidnight(localStart, timeZone);
  final endOffset = _offsetAtLocalMidnight(localEnd, timeZone);
  final start = localStart
      .subtract(Duration(minutes: startOffset))
      .millisecondsSinceEpoch;
  final end =
      localEnd.subtract(Duration(minutes: endOffset)).millisecondsSinceEpoch;
  if (end <= start)
    throw const FormatException('local day has no positive duration');
  return _LocalDayBounds(localDay, timeZone, start, end);
}

Map<String, dynamic> _dailyNocturnalRhrJson(Map<String, dynamic> input) {
  final localDay = input['local_day'];
  final timeZone = input['time_zone'];
  final rawSamples = input['samples'];
  if (localDay is! String || timeZone is! String || rawSamples is! List) {
    throw const FormatException(
        'daily nocturnal fixture requires local_day, time_zone, and samples');
  }
  final window = _localDayBounds(localDay, timeZone);
  final values = List<double>.filled(window.durationSeconds, 0);
  for (final raw in rawSamples) {
    if (raw is! Map)
      throw const FormatException('daily nocturnal sample must be an object');
    final timestamp =
        _number(raw['ts_ms'] ?? raw['timestamp_ms'], 'sample.ts_ms');
    final bpm = _number(raw['bpm'], 'sample.bpm');
    final offset = ((timestamp - window.startMs) / 1000).round();
    if (offset >= 0 && offset < values.length) values[offset] = bpm;
  }
  final result = nocturnalRhr(
    values,
    windowSamples: input['window_samples'] == null
        ? 1800
        : (input['window_samples'] as num).toInt(),
    minCoverage: input['min_coverage'] == null
        ? 0.9
        : _number(input['min_coverage'], 'min_coverage'),
  );
  final output = _metricJson(result, 'ana02.nocturnal.v1',
      (value) => (value as NocturnalRhr).toJson());
  if (result.value != null) {
    final value = Map<String, dynamic>.from(output['value'] as Map);
    value['local_day'] = window.localDay;
    value['time_zone'] = window.timeZone;
    value['day_start_ms'] = window.startMs;
    value['day_end_ms'] = window.endMs;
    value['day_duration_seconds'] = window.durationSeconds;
    output['value'] = value;
  }
  return output;
}

Map<String, dynamic> _rrQualityGateJson(Map<String, dynamic> input) {
  final correction = correctRr(
    _numbers(input['rr_ms'] ?? input['intervals_ms'], 'rr_ms'),
    alpha: input['alpha'] == null ? 5.2 : _number(input['alpha'], 'alpha'),
    windowBeats: input['window_beats'] == null
        ? 91
        : (input['window_beats'] as num).toInt(),
    minThresholdMs: input['min_threshold_ms'] == null
        ? 100
        : _number(input['min_threshold_ms'], 'min_threshold_ms'),
  );
  final minimumCleanFraction = input['min_clean_fraction'] == null
      ? 0.5
      : _number(input['min_clean_fraction'], 'min_clean_fraction');
  final minimumIntervals = input['min_intervals'] == null
      ? 30
      : (input['min_intervals'] as num).toInt();
  final accepted = correction.nn.length >= minimumIntervals &&
      correction.cleanFraction >= minimumCleanFraction;
  final output = <String, dynamic>{
    'value': accepted
        ? {
            'nn_ms': correction.nn.map(round6).toList(growable: false),
            'nn_times_ms':
                correction.nnTimesMs.map(round6).toList(growable: false),
            'classes':
                correction.classes.map((c) => c.name).toList(growable: false),
            'clean_fraction': round6(correction.cleanFraction),
            'dropped_count': correction.droppedCount,
            'corrected_count': correction.correctedCount,
          }
        : '—',
    'confidence':
        accepted ? round6(clamp(correction.cleanFraction, 0.3, 0.9)) : 0,
    'tier': Tier.high,
    'inputs_used': const ['rr_raw', 'rr_cleaned', 'rr_quality'],
    'note': accepted
        ? 'RR quality gate passed; cleaned NN is safe for downstream metrics'
        : 'RR quality below gate; cleaned RR metric withheld (need ≥$minimumIntervals clean beats and ≥${round6(minimumCleanFraction)} clean fraction)',
    'present': accepted,
    'algorithm_version': 'ana02.rr-quality.v1',
  };
  return output;
}

// The parity harness deliberately owns the JSON shape.  The pinned Dart
// primitives expose value objects, while the Swift side exposes the same
// equations through AnalyticsMetric.  These small adapters keep field names,
// absence, and provenance identical without changing either primitive.
List<bool> _bools(Object? value, String name) {
  if (value is! List) throw FormatException('$name must be an array');
  return value.map((v) {
    if (v is bool) return v;
    throw FormatException('$name must contain booleans');
  }).toList(growable: false);
}

List<String> _strings(Object? value, String name) {
  if (value is! List) throw FormatException('$name must be an array');
  return value.map((v) {
    if (v is String) return v;
    throw FormatException('$name must contain strings');
  }).toList(growable: false);
}

String _canonicalSleepStage(String value) {
  switch (value.toLowerCase()) {
    case 'wake':
      return 'wake';
    case 'rem':
      return 'rem';
    case 'deep':
    case 'light':
    case 'nrem':
      return 'nrem';
    default:
      throw FormatException('unknown sleep stage: $value');
  }
}

List<SleepStage> _sleepStages(Object? value, String name) =>
    _strings(value, name)
        .map((v) => SleepStage.values
            .firstWhere((s) => s.name == _canonicalSleepStage(v)))
        .toList(growable: false);

Map<String, dynamic> _canonicalMetric({
  required Object? value,
  required double confidence,
  required String tier,
  required List<String> inputs,
  required String note,
  required String algorithmVersion,
  List<Map<String, dynamic>>? drivers,
}) {
  final output = <String, dynamic>{
    'value': value ?? '—',
    'confidence': round6(value == null ? 0 : confidence),
    'tier': tier,
    'inputs_used': inputs,
    'note': note,
    'present': value != null,
    'algorithm_version': algorithmVersion,
  };
  if (drivers != null) output['drivers'] = drivers;
  return output;
}

Map<String, dynamic> _sleepCardioJson(Map<String, dynamic> input) {
  final features = CardioEpochFeatures(
    motion: _numbers(input['motion'], 'motion'),
    hr: _numbers(input['heart_rate'] ?? input['hr'], 'heart_rate'),
    hrSd: _numbers(input['heart_rate_sd'] ?? input['hr_sd'], 'heart_rate_sd'),
    rmssd: _numbers(input['rmssd'], 'rmssd'),
    lfhf: _numbers(input['lf_hf'] ?? input['lfhf'], 'lf_hf'),
    rk: _numbers(input['rk'], 'rk'),
    sdnn: _numbers(input['sdnn'], 'sdnn'),
  );
  final epoch = input['epoch_seconds'] == null
      ? 30
      : (input['epoch_seconds'] as num).toInt();
  final result = classifyCardioEpochs(features, epochSec: epoch);
  if (result.base.stages.isEmpty) {
    return _canonicalMetric(
      value: null,
      confidence: 0,
      tier: Tier.estimate,
      inputs: const ['cardio_epoch_features', 'hr_1hz'],
      note: 'too few epochs for cardiorespiratory staging',
      algorithmVersion: 'ana03.sleep.v1',
    );
  }
  final stages = result.base.stages.map((s) => s.name).toList(growable: false);
  final stages4 = <String>[];
  for (var i = 0; i < stages.length; i++) {
    final stage = stages[i];
    stages4
        .add(stage == 'nrem' && i < result.deepFlag.length && result.deepFlag[i]
            ? 'deep'
            : stage == 'nrem'
                ? 'light'
                : stage);
  }
  return _canonicalMetric(
    value: {
      'stages': stages,
      'stages4': stages4,
      'deep_flag': result.deepFlag,
      'epoch_sec': result.base.epochSec,
      'wake_pct': round6(result.base.wakePct),
      'nrem_pct': round6(result.base.nremPct),
      'rem_pct': round6(result.base.remPct),
    },
    confidence: result.confidence,
    tier: Tier.estimate,
    inputs: const ['cardio_epoch_features', 'hr_1hz'],
    note:
        'transparent cardio stager: motion + HR + robust RR axes; wrist estimate, not PSG',
    algorithmVersion: 'ana03.sleep.v1',
  );
}

Map<String, dynamic> _sleepFallbackJson(Map<String, dynamic> input) {
  final raw = input['heart_rate'] ?? input['hr'];
  if (raw is! List) throw const FormatException('heart_rate must be an array');
  final sampleBpm = <double>[];
  final sampleTs = <int>[];
  for (final item in raw) {
    if (item is! Map)
      throw const FormatException('heart_rate sample must be an object');
    sampleTs.add(_number(item['timestamp'] ?? item['ts_sec'] ?? item['ts'],
            'heart_rate.timestamp')
        .round());
    sampleBpm.add(item['valid'] is bool && item['valid'] == false
        ? 0.0
        : _number(item['bpm'] ?? item['hr'], 'heart_rate.bpm'));
  }
  final baseline = input['daytime_hr'] == null
      ? const <double>[]
      : _numbers(input['daytime_hr'], 'daytime_hr');
  final minDuration = input['min_duration_seconds'] == null
      ? 7200
      : (input['min_duration_seconds'] as num).toInt();
  final bridge = input['bridge_gap_seconds'] == null
      ? 1800
      : (input['bridge_gap_seconds'] as num).toInt();
  final smoothing = input['smoothing_seconds'] == null
      ? 300
      : (input['smoothing_seconds'] as num).toInt();
  final result = hrLedSleepWindow(sampleBpm, sampleTs,
      hrBaseline: baseline,
      minDurationSec: minDuration,
      bridgeGapSec: bridge,
      smoothSec: smoothing.toDouble());
  final value = result == null
      ? null
      : {
          'onset_sec': result.onsetSec,
          'offset_sec': result.offsetSec,
          'duration_sec': result.durationSec,
          'threshold_bpm': round6(result.thresholdBpm),
        };
  return _canonicalMetric(
    value: value,
    confidence: result == null ? 0 : 0.3,
    tier: Tier.estimate,
    inputs:
        baseline.isEmpty ? const ['hr_1hz'] : const ['hr_1hz', 'daytime_hr'],
    note: result == null
        ? (baseline.isEmpty
            ? 'no sustained nocturnal HR dip found'
            : 'no sustained nocturnal HR dip found')
        : 'HR-led candidate only; user confirmation required before staging',
    algorithmVersion: 'ana03.sleep.v1',
  );
}

Map<String, dynamic> _sleepSegmentationJson(Map<String, dynamic> input) {
  final timeZone = _sleepTimeZone(input['time_zone_identifier']);
  final rawAccel = input['acceleration'];
  final rawHeart = input['heart_rate'];
  final rawRr = input['rr'];
  if (rawAccel is! List || rawHeart is! List || rawRr is! List) {
    throw const FormatException(
        'sleepSegmentation requires acceleration, heart_rate, and rr arrays');
  }
  final accel = rawAccel.map((raw) {
    if (raw is! Map)
      throw const FormatException('acceleration sample must be an object');
    return AccelSample(
      _number(raw['timestamp'], 'acceleration.timestamp') * 1000,
      _number(raw['x'], 'acceleration.x'),
      _number(raw['y'], 'acceleration.y'),
      _number(raw['z'], 'acceleration.z'),
      valid: raw['valid'] as bool? ?? true,
    );
  }).toList(growable: false);
  final heartByTimestamp = <double, double>{};
  for (final raw in rawHeart) {
    if (raw is! Map)
      throw const FormatException('heart-rate sample must be an object');
    if (raw['valid'] as bool? ?? true) {
      heartByTimestamp[_number(raw['timestamp'], 'heart_rate.timestamp')] =
          _number(raw['bpm'], 'heart_rate.bpm');
    }
  }
  final heart = accel
      .map((sample) => heartByTimestamp[sample.tsMs / 1000] ?? 0.0)
      .toList(growable: false);
  final rrMs = <double>[];
  final rrTsMs = <double>[];
  for (final raw in rawRr) {
    if (raw is! Map) throw const FormatException('RR sample must be an object');
    rrMs.add(_number(raw['milliseconds'] ?? raw['rr_ms'], 'rr.milliseconds'));
    rrTsMs.add(_number(raw['timestamp'], 'rr.timestamp') * 1000);
  }
  final result = segmentSleep(
    accel,
    heart,
    rrMs: rrMs,
    rrTsMs: rrTsMs,
    tzOffsetResolver: timeZone.offsetAt,
  );
  return _canonicalMetric(
    value: result.window == null ? null : result.toJson(),
    confidence: result.confidence,
    tier: Tier.estimate,
    inputs: const ['accel_1hz', 'hr_1hz', 'rr_cleaned'],
    note: result.window == null
        ? 'no qualifying sleep window'
        : 'single-source sleep segmentation',
    algorithmVersion: 'ana03.sleep.v1',
  );
}

Map<String, dynamic> _sleepAccountingJson(Map<String, dynamic> input) {
  final asleep = _bools(input['asleep'], 'asleep');
  final stages =
      input['stages'] == null ? null : _sleepStages(input['stages'], 'stages');
  final result = sleepAccounting(asleep, stages: stages);
  return _canonicalMetric(
    value: result.value?.toJson(),
    confidence: result.confidence,
    tier: Tier.high,
    inputs: stages == null
        ? const ['in_bed_sleep_wake']
        : const ['in_bed_sleep_wake', 'stages'],
    note: result.present
        ? 'onset/offset/WASO/TST/efficiency; cycles ~90-min ultradian (REM-episode count when staged); 3-class only, never N1/N2/N3'
        : (asleep.length < 60
            ? 'in-bed window too short for sleep accounting'
            : 'no sleep detected within the in-bed window'),
    algorithmVersion: 'ana03.sleep.v1',
  );
}

Map<String, dynamic> _sleepRegularityJson(Map<String, dynamic> input) {
  final result = phillipsSri(_bools(input['asleep'], 'asleep'),
      (input['epochs_per_day'] as num).toInt());
  return _canonicalMetric(
    value: result.value?.toJson(),
    confidence: result.confidence,
    tier: Tier.high,
    inputs: const ['sleep_wake_epochs'],
    note: result.present
        ? 'epoch-by-epoch 24-h concordance (Phillips 2017), SRI=200·agreement/cases−100; NOT SD-of-midsleep'
        : 'need ≥2 full days of clock-aligned sleep/wake epochs for SRI',
    algorithmVersion: 'ana03.sleep.v1',
  );
}

Map<String, dynamic> _sleepHypnogramJson(Map<String, dynamic> input) {
  final start = (input['start'] as num?)?.toInt();
  final end = (input['end'] as num?)?.toInt();
  final rawSegments = input['stage_segments'];
  if (start == null || end == null || end < start || rawSegments is! List) {
    throw const FormatException(
        'sleepHypnogram requires start, end, and stage_segments');
  }
  final segments = rawSegments.map((raw) {
    if (raw is! Map)
      throw const FormatException('stage_segments entries must be objects');
    final segmentStart = (raw['start'] as num?)?.toInt();
    final segmentEnd = (raw['end'] as num?)?.toInt();
    final stage = raw['stage'];
    if (segmentStart == null || segmentEnd == null || stage is! String) {
      throw const FormatException(
          'stage segment requires integer start/end and stage');
    }
    if (segmentEnd < segmentStart)
      throw const FormatException('stage segment end precedes start');
    return StageSegment(segmentStart, segmentEnd, stage.toLowerCase());
  }).toList(growable: false);
  final session = SleepSession(
    start: start,
    end: end,
    efficiency: 0,
    stages: segments,
    restingHr: null,
    avgHrv: null,
  );
  final result = AdvancedSleepStager.hypnogramMetrics(session);
  return _canonicalMetric(
    value: result.toJson(),
    confidence: 1,
    tier: Tier.high,
    inputs: const ['sleep_stages'],
    note: 'AASM hypnogram metrics from the shared staged session',
    algorithmVersion: 'ana03.sleep.v1',
  );
}

Map<String, dynamic> _sleepDayAssignmentJson(Map<String, dynamic> input) {
  final endTimestamp =
      _number(input['sleep_end_timestamp'], 'sleep_end_timestamp');
  final timeZone = input['time_zone_identifier'];
  if (timeZone is! String)
    throw const FormatException('time_zone_identifier must be a string');
  final localDay = _localDayForTimestamp(endTimestamp, timeZone);
  final bounds = _localDayBounds(localDay, timeZone);
  return _canonicalMetric(
    value: {
      'day': localDay,
      'day_start_ms': bounds.startMs,
      'day_end_ms': bounds.endMs,
      'day_duration_seconds': bounds.durationSeconds,
    },
    confidence: 1,
    tier: Tier.high,
    inputs: const ['sleep_end', 'time_zone'],
    note: 'main sleep is assigned to the local calendar day on which it ends',
    algorithmVersion: 'ana03.sleep.v1',
  );
}

Map<String, dynamic> _readinessJson(Map<String, dynamic> input) {
  final rawInputs = input['inputs'];
  if (rawInputs is! List)
    throw const FormatException('readiness inputs must be an array');
  final inputs = <ReadinessInput>[];
  for (final raw in rawInputs) {
    if (raw is! Map)
      throw const FormatException('readiness input must be an object');
    final metric = raw['metric'];
    final metricMap = metric is Map ? metric : const <String, dynamic>{};
    final value = metricMap['value'] is num
        ? (metricMap['value'] as num).toDouble()
        : raw['value'] is num
            ? (raw['value'] as num).toDouble()
            : null;
    inputs.add(ReadinessInput(
      raw['label'] as String,
      value,
      _numbers(raw['baseline'], 'readiness.baseline'),
      (raw['good_sign'] as num).toInt(),
      _number(raw['weight'], 'readiness.weight'),
    ));
  }
  // DEC-05.4 deliberately diverges from pinned upstream readiness v1.
  // Independent reference for Loopr v2. Tolerances remain unchanged.
  double median(List<double> values) {
    final sorted = [...values]..sort();
    final m = sorted.length ~/ 2;
    return sorted.length.isEven ? (sorted[m - 1] + sorted[m]) / 2 : sorted[m];
  }
  final minBaseline = (input['min_baseline'] as num?)?.toInt() ?? 3;
  final used = <String>[];
  final drivers = <Map<String, dynamic>>[];
  final seen = <String>{};
  double weights = 0, weightedZ = 0;
  final counts = <int>[];
  for (final row in inputs) {
    if (!seen.add(row.label) || row.weight <= 0 || row.value == null || !row.value!.isFinite) continue;
    final prior = row.baseline.where((v) => v.isFinite).toList();
    if (prior.length < minBaseline) { counts.add(prior.length); continue; }
    if (prior.length < 2 || prior.toSet().length < 2) continue;
    final center = median(prior);
    final mean = prior.reduce((a, b) => a + b) / prior.length;
    final sd = math.sqrt(prior.map((v) => math.pow(v - mean, 2).toDouble()).reduce((a, b) => a + b) / (prior.length - 1));
    if (sd <= 0 || row.label == 'RHR' && sd < 1) continue;
    counts.add(prior.length);
    final floor = row.label == 'HRV' ? 0.10 : row.label == 'RR' ? 0.5 : 0.0;
    final mad = 1.4826 * median(prior.map((v) => (v - center).abs()).toList());
    final spread = math.max(math.max(mad, sd), floor);
    final z = row.goodSign * (row.value! - center) / (spread * math.sqrt(1 + 1 / prior.length)) * math.sqrt(math.min(prior.length, 14) / 14);
    used.add(row.label); weights += row.weight; weightedZ += row.weight * z;
    drivers.add({'label': row.label, 'contribution': row.weight * z,
      'detail': 'oriented median with guarded dispersion and early-history caution=${round6(z)}'});
  }
  if (used.length < 2 || weights < 0.5) {
    counts.sort((a, b) => b.compareTo(a));
    final have = counts.length >= 2 ? counts[1] : minBaseline;
    return _canonicalMetric(value: null, confidence: 0, tier: Tier.estimate, inputs: [],
      note: have < minBaseline ? 'need_baseline:have=$have,need=$minBaseline' : 'need_inputs: at least two usable overnight readings; no readiness from one input',
      algorithmVersion: 'loopr.readiness.2.honest');
  }
  final composite = weightedZ / weights;
  for (final driver in drivers) { driver['contribution'] = round6((driver['contribution'] as double) / weights); }
  drivers.sort((a, b) => (b['contribution'] as double).abs().compareTo((a['contribution'] as double).abs()));
  return _canonicalMetric(value: {'score': round6(100 / (1 + math.exp(-composite))),
    'composite_z': round6(composite), 'meaningful': composite.abs() > ((input['swc_multiplier'] as num?)?.toDouble() ?? 0.2)},
    confidence: math.min(0.9, 0.3 + 0.15 * used.length), tier: Tier.estimate, inputs: used,
    note: 'Recovery v2: two inputs, guarded dispersion and early-history caution. Drivers describe the formula, not causes.',
    algorithmVersion: 'loopr.readiness.2.honest', drivers: drivers);

}

Map<String, dynamic> _stressJson(Map<String, dynamic> input) {
  final result = baevskyStressIndex(
      _numbers(input['rr_ms'] ?? input['nn_ms'], 'rr_ms'),
      minRangeMs: input['min_range_ms'] == null
          ? 20
          : _number(input['min_range_ms'], 'min_range_ms'));
  return _canonicalMetric(
    value: result.value?.toJson(),
    confidence: result.confidence,
    tier: Tier.estimate,
    inputs: const ['rr_cleaned'],
    note: result.present
        ? 'Baevsky Stress Index — median of ~5-min-window SI (AMo/(2·Mo·MxDMn)); resting autonomic tension, PRV — not psychological.'
        : (result.note ?? 'need ≥30 clean beats for a Stress Index histogram'),
    algorithmVersion: 'ana04.wellness.v1',
  );
}

Map<String, dynamic> _anomalyJson(Map<String, dynamic> input) {
  final dates = _strings(input['dates'], 'dates');
  final rawFeatures = _mapList(input['features'], 'features');
  if (dates.length != rawFeatures.length) {
    throw const FormatException(
        'anomaly dates and features must have equal length');
  }
  // The public Loopr surface intentionally omits absolute temperature.  Keep
  // the pinned Dart primitive's fourth dimension null so both adapters score
  // the same three approved features (RHR, HRV and respiration) without
  // inventing a temperature value.
  final features = rawFeatures
      .map((raw) => AnomalyFeatures(
            rhr: _optionalNumber(raw['rhr'] ?? raw['resting_heart_rate'],
                'features.resting_heart_rate'),
            hrv: _optionalNumber(raw['hrv'], 'features.hrv'),
            temp: _optionalNumber(
                raw['temp'] ?? raw['temperature'], 'features.temp'),
            resp: _optionalNumber(
                raw['resp'] ?? raw['respiration'], 'features.respiration'),
          ))
      .toList(growable: false);
  final result = multivariateAnomaly(
    dates,
    features,
    baselineDays: input['baseline_days'] == null
        ? 28
        : (input['baseline_days'] as num).toInt(),
    minBaseline: input['min_baseline'] == null
        ? multivariateAnomalyMinBaseline
        : (input['min_baseline'] as num).toInt(),
    chiSqGate: _optionalNumber(
        input['chi_square_gate'] ?? input['chi_sq_gate'], 'chi_square_gate'),
    persistDays: input['persist_days'] == null
        ? 2
        : (input['persist_days'] as num).toInt(),
    ridge: input['ridge'] == null ? 0.1 : _number(input['ridge'], 'ridge'),
  );
  return _canonicalMetric(
    value: result.map((day) => day.toJson()).toList(growable: false),
    confidence: result.isEmpty ? 0 : 0.6,
    tier: Tier.estimate,
    inputs: const ['nightly_features', 'prior_baseline'],
    note: 'robust multivariate anomaly complement; no diagnosis',
    algorithmVersion: 'ana04.wellness.v1',
  );
}

Map<String, dynamic> _changePointJson(Map<String, dynamic> input) {
  final values = _numbers(input['values'], 'values');
  final minSegment =
      input['min_segment'] == null ? 7 : (input['min_segment'] as num).toInt();
  final result = segmentChangePoints(
    values,
    minSeg: minSegment,
    penaltyK: input['penalty_multiplier'] == null
        ? 1
        : _number(input['penalty_multiplier'], 'penalty_multiplier'),
    penaltyOverride:
        _optionalNumber(input['penalty_override'], 'penalty_override'),
  );
  final note = result.present
      ? 'binary segmentation w/ BIC-penalized change-in-mean; min-seg=$minSegment. Run on SMOOTHED aggregates only — do not celebrate regression-to-mean.'
      : 'series shorter than 2× min-segment; no change-point search';
  return _canonicalMetric(
    value: result.value?.toJson(),
    confidence: result.confidence,
    tier: Tier.estimate,
    inputs: const ['daily_aggregate'],
    note: note,
    algorithmVersion: 'ana04.wellness.v1',
  );
}

Map<String, dynamic> _illnessCusumJson(Map<String, dynamic> input) {
  final dates = _strings(input['dates'], 'dates');
  final rhr = _nullableNumbers(
      input['resting_heart_rate'] ?? input['rhr'], 'resting_heart_rate');
  if (dates.length != rhr.length) {
    throw const FormatException(
        'illnessCusum dates and resting_heart_rate must have equal length');
  }
  final result = illnessCusum(
    dates,
    rhr,
    baselineDays: input['baseline_days'] == null
        ? 28
        : (input['baseline_days'] as num).toInt(),
    k: input['k'] == null ? 0.5 : _number(input['k'], 'k'),
    h: input['threshold'] == null
        ? 4
        : _number(input['threshold'], 'threshold'),
    persistDays: input['persist_days'] == null
        ? 2
        : (input['persist_days'] as num).toInt(),
    minBaseline: input['min_baseline'] == null
        ? illnessCusumMinBaseline
        : (input['min_baseline'] as num).toInt(),
    returnZ: input['return_z'] == null
        ? 0.5
        : _number(input['return_z'], 'return_z'),
    recoverDays: input['recover_days'] == null
        ? 2
        : (input['recover_days'] as num).toInt(),
  );
  return _canonicalMetric(
    value: result.map((day) => day.toJson()).toList(growable: false),
    confidence: result.isEmpty ? 0 : 0.6,
    tier: Tier.estimate,
    inputs: const ['nightly_rhr', 'prior_baseline'],
    note: 'NightSignal/CUSUM illness signal; elevated RHR is not a diagnosis',
    algorithmVersion: 'ana04.wellness.v1',
  );
}

List<Map<String, dynamic>> _mapList(Object? value, String name) {
  if (value is! List) throw FormatException('$name must be an array');
  return value.map((raw) {
    if (raw is! Map) throw FormatException('$name entries must be objects');
    return Map<String, dynamic>.from(raw);
  }).toList(growable: false);
}

Map<String, dynamic> _staticTiltJson(Map<String, dynamic> input) {
  final samples = _mapList(input['samples'] ?? input['epoch'], 'samples')
      .map((raw) => AccelSample(
            _number(raw['timestamp'] ?? raw['ts_ms'] ?? raw['ts'],
                'sample.timestamp'),
            _number(raw['x'], 'sample.x'),
            _number(raw['y'], 'sample.y'),
            _number(raw['z'], 'sample.z'),
            valid: raw['valid'] is bool ? raw['valid'] as bool : true,
          ))
      .toList(growable: false);
  final result = staticTilt(samples,
      maxJitterG: input['max_jitter_g'] == null
          ? 0.05
          : _number(input['max_jitter_g'], 'max_jitter_g'),
      minSamples: input['min_samples'] == null
          ? 3
          : (input['min_samples'] as num).toInt());
  return _canonicalMetric(
    value: result.value?.toJson(),
    confidence: result.confidence,
    tier: Tier.high,
    inputs: const ['accel_1hz'],
    note: result.present
        ? 'wrist gravity-tilt; body-position PROXY (static, low-motion only)'
        : (result.note ?? 'epoch too short for a static-tilt estimate'),
    algorithmVersion: 'ana05.activity.v1',
  );
}

Map<String, dynamic> _energyFusionJson(Map<String, dynamic> input) {
  final result = branchedEnergyFusion(
    _numbers(input['timestamps'] ?? input['ts_ms'], 'timestamps'),
    _numbers(input['enmo'], 'enmo'),
    _numbers(input['heart_rate'] ?? input['hr'], 'heart_rate'),
    restingHr: _optionalNumber(input['resting_hr'], 'resting_hr'),
    maxHr: _optionalNumber(input['max_hr'], 'max_hr'),
    accelSatG: input['accel_saturation_g'] == null
        ? 0.5
        : _number(input['accel_saturation_g'], 'accel_saturation_g'),
    accelHi: input['accel_high'] == null
        ? 0.15
        : _number(input['accel_high'], 'accel_high'),
    hrHi: input['hr_high'] == null ? 0.4 : _number(input['hr_high'], 'hr_high'),
  );
  final value = result.value == null
      ? null
      : {
          'points': result.value!.points
              .map((p) => {
                    'timestamp': round6(p.tsMs),
                    'index': round6(p.index),
                    'accel_component': round6(p.accelComponent),
                    'hr_component': round6(p.hrComponent),
                    'accel_weight': round6(p.accelWeight),
                    'branch': p.branch,
                  })
              .toList(growable: false),
          'relative_load': round6(result.value!.relativeLoad),
          'calibrated': result.value!.calibrated,
        };
  return _canonicalMetric(
      value: value,
      confidence: result.confidence,
      tier: result.tier,
      inputs: const ['enmo_1hz', 'hr_1hz', 'resting_hr?', 'max_hr?'],
      note: result.value?.calibrated == true
          ? 'Brage branched fusion w/ %HR-reserve; ESTIMATE EE, not kcal/METs'
          : 'Brage branched fusion; RELATIVE EE index (no per-user HR calib)',
      algorithmVersion: 'ana05.activity.v1');
}

WorkoutUserProfile _workoutProfile(
    Map<String, dynamic>? raw, Map<String, dynamic> input) {
  final source = raw ??
      <String, dynamic>{
        'weight_kg': input['weight_kg'],
        'height_cm': input['height_cm'],
        'age': input['age'],
        'sex': input['sex'],
      };
  return WorkoutUserProfile(
    weightKg: source['weight_kg'] is num
        ? (source['weight_kg'] as num).toDouble()
        : 70,
    heightCm: source['height_cm'] is num
        ? (source['height_cm'] as num).toDouble()
        : 170,
    age: source['age'] is num ? (source['age'] as num).toDouble() : 30,
    sex: source['sex'] as String? ?? 'nonbinary',
  );
}

Map<String, dynamic> _workoutSessionJson(ExerciseSession s) => s.toJson();

Map<String, dynamic> _workoutDetectJson(Map<String, dynamic> input) {
  final rawHR = _mapList(input['heart_rate'] ?? input['hr'], 'heart_rate');
  final hrTs = <int>[];
  final hrBpm = <double>[];
  for (final raw in rawHR) {
    hrTs.add(
        _number(raw['timestamp'] ?? raw['ts'], 'heart_rate.timestamp').round());
    hrBpm.add(_number(raw['bpm'] ?? raw['hr'], 'heart_rate.bpm'));
  }
  final rawMotion = _mapList(input['motion'], 'motion');
  final gravTs = <int>[];
  final gx = <double>[];
  final gy = <double>[];
  final gz = <double>[];
  var accumulated = 0.0;
  for (final raw in rawMotion) {
    final intensity =
        _number(raw['intensity'] ?? raw['enmo'] ?? 0, 'motion.intensity');
    gravTs.add(
        _number(raw['timestamp'] ?? raw['ts'], 'motion.timestamp').round());
    gx.add(accumulated);
    gy.add(0);
    gz.add(0);
    accumulated += intensity;
  }
  final profileRaw = input['profile'] is Map
      ? Map<String, dynamic>.from(input['profile'] as Map)
      : null;
  final profile = profileRaw == null &&
          (input['weight_kg'] != null ||
              input['height_cm'] != null ||
              input['sex'] != null)
      ? _workoutProfile(null, input)
      : profileRaw == null
          ? null
          : _workoutProfile(profileRaw, input);
  final result = detectWorkouts(
    hrTs: hrTs,
    hrBpm: hrBpm,
    gravTs: gravTs,
    gx: gx,
    gy: gy,
    gz: gz,
    restingHR: _optionalNumber(input['resting_hr'], 'resting_hr'),
    maxHR: _optionalNumber(input['max_hr'], 'max_hr'),
    age: _optionalNumber(input['age'], 'age'),
    profile: profile,
  );
  return _canonicalMetric(
    value: result.value?.map(_workoutSessionJson).toList(growable: false),
    confidence: result.confidence,
    tier: Tier.estimate,
    inputs: const [
      'hr_1hz',
      'gravity_1hz',
      'profile',
      'max_hr',
      'age',
      'resting_hr'
    ],
    note: result.value == null
        ? (result.note ?? 'no HR or motion stream for workout detection')
        : 'detected workouts (HR + motion gated, ≥5 min, ≥50% time in zone 2+); wrist-HR ESTIMATE, not medical advice',
    algorithmVersion: 'ana06.workout.v1',
  );
}

Map<String, dynamic> _hrRecoveryJson(Map<String, dynamic> input) {
  final values = _numbers(input['heart_rate'] ?? input['hr'], 'heart_rate');
  final recoverySeconds = input['recovery_window_seconds'] == null
      ? 60
      : (input['recovery_window_seconds'] as num).toInt();
  final result = hrRecovery(
      values.map((v) => v.round()).toList(growable: false),
      endIndex: input['end_index'] == null
          ? null
          : (input['end_index'] as num).toInt(),
      recoverySec: recoverySeconds,
      peakWindowSec: input['peak_window_seconds'] == null
          ? 30
          : (input['peak_window_seconds'] as num).toInt());
  final note = result.present
      ? 'HRR-${recoverySeconds}s = peak − HR@+${recoverySeconds}s. Higher = faster parasympathetic reactivation (fitter). PRV not ECG.'
      : (result.note?.contains('too short') == true
          ? 'HR tail too short to reach +${recoverySeconds}s recovery point'
          : result.note?.contains('no HR tail') == true
              ? 'no HR tail for HRR'
              : result.note?.contains('did not descend') == true
                  ? 'HR did not descend after exercise end — likely still active'
                  : result.note ??
                      'off-skin or missing HR around the recovery point');
  return _canonicalMetric(
      value: result.value?.toJson(),
      confidence: result.confidence,
      tier: Tier.estimate,
      inputs: const ['hr_1hz'],
      note: note,
      algorithmVersion: 'ana06.workout.v1');
}

Map<String, dynamic> _dayCurvesJson(Map<String, dynamic> input) {
  final dates = _strings(input['dates'], 'dates');
  final values = _numbers(input['values'], 'values');
  final minimum = input['minimum_history'] == null
      ? 14
      : (input['minimum_history'] as num).toInt();
  final curves = <Map<String, dynamic>>[];
  for (var i = 0; i < dates.length && i < values.length; i++) {
    final prior = <double>[];
    for (var j = 0; j < dates.length && j < values.length; j++) {
      if (dates[j].compareTo(dates[i]) < 0 && values[j].isFinite)
        prior.add(values[j]);
    }
    double? percentile;
    if (prior.length >= minimum) {
      final below = prior.where((v) => v < values[i]).length;
      final equal = prior.where((v) => v == values[i]).length;
      percentile = 100 * (below + equal * 0.5) / prior.length;
    }
    curves.add({
      'date': dates[i],
      'value': round6(values[i]),
      'percentile_of_you': percentile == null ? null : round6(percentile),
      'prior_count': prior.length
    });
  }
  return _canonicalMetric(
      value: curves,
      confidence: curves.isEmpty ? 0 : 0.6,
      tier: Tier.high,
      inputs: const ['daily_aggregate'],
      note: 'date-scoped day curve; target day excluded from prior history',
      algorithmVersion: 'ana06.workout.v1');
}

Map<String, dynamic> _boutCaloriesJson(Map<String, dynamic> input) {
  final ts = _numbers(input['timestamps'] ?? input['ts_sec'], 'timestamps')
      .map((v) => v.round())
      .toList(growable: false);
  final hr = _numbers(input['heart_rate'] ?? input['hr'], 'heart_rate');
  final profile = _workoutProfile(
      input['profile'] is Map
          ? Map<String, dynamic>.from(input['profile'] as Map)
          : null,
      input);
  final result = Calories.estimateBoutCalories(ts, hr,
      profile: profile,
      hrmax: _optionalNumber(input['max_hr'], 'max_hr'),
      restingHr: _optionalNumber(input['resting_hr'], 'resting_hr'));
  final value = {
    'kcal': round6(result.kcal),
    'kj': round6(result.kj),
    'used_default_anchors': result.usedDefaultAnchors
  };
  return _canonicalMetric(
      value: value,
      confidence: result.usedDefaultAnchors ? 0.35 : 0.65,
      tier: Tier.estimate,
      inputs: const ['hr_bout', 'workout_profile', 'hrmax?', 'resting_hr?'],
      note: result.usedDefaultAnchors
          ? 'Keytel/Harris–Benedict estimate using default HR anchor(s); caveat required'
          : 'Keytel/Harris–Benedict HR calorie estimate',
      algorithmVersion: 'ana06.workout.v1');
}

Map<String, dynamic> _dailyEnergyJson(Map<String, dynamic> input) {
  final profile = _workoutProfile(
      input['profile'] is Map
          ? Map<String, dynamic>.from(input['profile'] as Map)
          : null,
      input);
  final result = Calories.dailyEnergy(
      _numbers(input['heart_rate'] ?? input['hr'], 'heart_rate'),
      profile: profile,
      hrmax: _optionalNumber(input['max_hr'], 'max_hr'),
      activeFraction: input['active_fraction'] == null
          ? 0.5
          : _number(input['active_fraction'], 'active_fraction'),
      dayMinutes:
          input['minutes'] == null ? 1440 : (input['minutes'] as num).toInt());
  final value = {
    'total_kcal': round6(result.total),
    'active_kcal': round6(result.active),
    'basal_kcal': round6(result.basal),
    'used_default_hrmax': result.usedDefaultHrmax
  };
  return _canonicalMetric(
      value: value,
      confidence: result.usedDefaultHrmax ? 0.35 : 0.6,
      tier: Tier.estimate,
      inputs: const ['hr_per_min', 'workout_profile', 'hrmax?'],
      note: result.usedDefaultHrmax
          ? 'Mifflin + HR-flex estimate using default HRmax'
          : 'Mifflin + HR-flex daily energy estimate',
      algorithmVersion: 'ana06.workout.v1');
}

String _localDayForTimestamp(double seconds, String timeZone) {
  final utc = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round(),
      isUtc: true);
  final offset = _offsetAtLocalMidnight(utc, timeZone);
  final local = utc.add(Duration(minutes: offset));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}';
}

Map<String, dynamic> _stepCounterJson(Map<String, dynamic> input) {
  final timeZone = input['time_zone_identifier'] as String? ?? 'UTC';
  final raw = _mapList(input['readings'], 'readings');
  final readings = raw
      .map((r) => {
            'timestamp':
                _number(r['timestamp'] ?? r['ts_sec'], 'reading.timestamp'),
            'steps': (_number(r['cumulative_steps'] ?? r['steps'],
                    'reading.cumulative_steps'))
                .round(),
            'valid': r['valid'] is bool ? r['valid'] as bool : true,
          })
      .where((r) =>
          r['valid'] == true &&
          (r['timestamp'] as double).isFinite &&
          (r['timestamp'] as double) >= 0 &&
          (r['steps'] as int) >= 0)
      .toList()
    ..sort((a, b) =>
        (a['timestamp'] as double).compareTo(b['timestamp'] as double));
  final aggregates = <String, Map<String, dynamic>>{};
  var previousTimestamp = 0.0;
  var previousSteps = 0;
  var havePrevious = false;
  var resetCount = 0;
  var backlogTotal = 0;
  for (final reading in readings) {
    final timestamp = reading['timestamp'] as double;
    final steps = reading['steps'] as int;
    final day = _localDayForTimestamp(timestamp, timeZone);
    var delta = 0;
    var reset = false;
    var backlog = 0;
    if (havePrevious && timestamp > previousTimestamp) {
      if (steps >= previousSteps) {
        delta = steps - previousSteps;
        if (timestamp - previousTimestamp >
            (input['backlog_gap_seconds'] == null
                ? 86400
                : _number(
                    input['backlog_gap_seconds'], 'backlog_gap_seconds'))) {
          backlog = delta;
          backlogTotal += delta;
        }
      } else {
        delta = steps;
        reset = true;
        resetCount++;
      }
    }
    final current = aggregates[day] ??
        {'steps': 0, 'reset_detected': false, 'backlog_steps': 0};
    current['steps'] = (current['steps'] as int) + delta;
    current['reset_detected'] = (current['reset_detected'] as bool) || reset;
    current['backlog_steps'] = (current['backlog_steps'] as int) + backlog;
    aggregates[day] = current;
    previousTimestamp = timestamp;
    previousSteps = steps;
    havePrevious = true;
  }
  final days = aggregates.keys.toList()..sort();
  final value = <String, dynamic>{
    'days': [
      for (final day in days)
        {
          'day': (() {
            final parts = day.split('-').map(int.parse).toList(growable: false);
            return {
              'era': 1,
              'year': parts[0],
              'month': parts[1],
              'day': parts[2]
            };
          })(),
          ...aggregates[day]!,
        }
    ],
    'total_steps':
        aggregates.values.fold<int>(0, (sum, row) => sum + row['steps'] as int),
    'reset_count': resetCount,
    'backlog_steps': backlogTotal,
  };
  final validCount = readings.length;
  return _canonicalMetric(
      value: validCount == 0 || days.isEmpty ? null : value,
      confidence: validCount == 0 ? 0 : (validCount / 8).clamp(0.35, 0.9),
      tier: Tier.estimate,
      inputs: const ['step_counter', 'local_day', 'counter_reset', 'backlog'],
      note: validCount == 0
          ? 'no valid cumulative step-counter readings'
          : 'cumulative step counter reconciled with reset and multi-day backlog diagnostics',
      algorithmVersion: 'ana05.activity.v1');
}

Map<String, dynamic> _run(Map<String, dynamic> input) {
  final metric = input['metric'];
  if (metric is! String || metric.isEmpty)
    throw const FormatException('fixture.metric must be a non-empty string');
  switch (metric) {
    case 'strain':
      final result = trimpStrain(
        _numbers(input['hr'], 'hr'),
        _numbers(input['timestamps'], 'timestamps'),
        restingHr: _optionalNumber(input['resting_hr'], 'resting_hr'),
        maxHr: _optionalNumber(input['max_hr'], 'max_hr'),
        method: input['method'] as String? ?? 'edwards',
      );
      return _metricJson(result, 'ana05.activity.v1');
    case 'strainScoreMetric':
      final value = strainScoreMetric(_optionalNumber(input['trimp'], 'trimp'));
      return _metricJson(value, 'ana05.strain.v1');
    case 'correctRr':
    case 'rrCorrection':
      final result = correctRr(
          _numbers(input['rr_ms'] ?? input['intervals_ms'], 'rr_ms'),
          alpha:
              input['alpha'] == null ? 5.2 : _number(input['alpha'], 'alpha'),
          windowBeats: input['window_beats'] == null
              ? 91
              : (input['window_beats'] as num).toInt(),
          minThresholdMs: input['min_threshold_ms'] == null
              ? 100
              : _number(input['min_threshold_ms'], 'min_threshold_ms'));
      return {
        'nn_ms': result.nn.map(round6).toList(growable: false),
        'nn_times_ms': result.nnTimesMs.map(round6).toList(growable: false),
        'classes': result.classes.map((c) => c.name).toList(growable: false),
        'clean_fraction': round6(result.cleanFraction),
        'dropped_count': result.droppedCount,
        'corrected_count': result.correctedCount,
        'present': result.nn.isNotEmpty,
        'algorithm_version': 'ana02.rr-quality.v1',
      };
    case 'rrQualityGate':
      return _rrQualityGateJson(input);
    case 'ppgTrust':
      final result = ppgTrust(
          _numbers(input['ppg'] ?? input['ppg_window'], 'ppg'),
          _number(input['hr_bpm'], 'hr_bpm'),
          skewMin: input['skew_min'] == null
              ? -0.1
              : _number(input['skew_min'], 'skew_min'));
      return {
        'trusted': result.trusted,
        'skewness': round6(result.skewness),
        'reasons': result.reasons,
        'present': result.trusted,
        'algorithm_version': 'ana02.rr-quality.v1',
      };
    case 'robustBaseline':
      final result = robustBaseline(_numbers(input['values'], 'values'),
          minValid: input['min_valid'] == null
              ? 3
              : (input['min_valid'] as num).toInt());
      return {
        'center': result.center == null ? null : round6(result.center!),
        'scale': result.scale == null ? null : round6(result.scale!),
        'n_valid': result.nValid,
        'n_window': result.nWindow,
        'sufficient': result.sufficient,
        'present': result.sufficient,
        'algorithm_version': 'ana02.baseline.v1',
      };
    case 'gapAwareEwma':
      final points = gapAwareEwma(_numbers(input['times_ms'], 'times_ms'),
          _numbers(input['values'], 'values'),
          halfLifeMs: _number(input['half_life_ms'], 'half_life_ms'),
          maxGapMs: input['max_gap_ms'] == null
              ? 0
              : _number(input['max_gap_ms'], 'max_gap_ms'));
      return {
        'points': points
            .map((p) => {'value': round6(p.value), 'gap': p.gap})
            .toList(growable: false),
        'present': points.isNotEmpty,
        'algorithm_version': 'ana02.baseline.v1',
      };
    case 'baselineUpdate':
      final cfg = _metricCfg(input['configuration'] as String? ?? 'hrv');
      BaselineState? state;
      if (input['state'] is Map) state = _decodeBaseline(input['state'] as Map);
      final result = Baselines.update(
          state,
          input.containsKey('value')
              ? (input['value'] == null
                  ? null
                  : _number(input['value'], 'value'))
              : null,
          cfg);
      return {
        ...result.toJson(),
        'present': result.nValid > 0,
        'algorithm_version': 'ana02.baseline.v1'
      };
    case 'baselineFoldHistory':
      final result = Baselines.foldHistory(
          _nullableNumbers(input['values'], 'values'),
          _metricCfg(input['configuration'] as String? ?? 'hrv'));
      return {
        ...result.toJson(),
        'present': result.nValid > 0,
        'algorithm_version': 'ana02.baseline.v1'
      };
    case 'baselineFoldPrior':
      final target = DateTime.parse(input['target_day'] as String);
      final rawSamples = input['samples'];
      if (rawSamples is! List)
        throw const FormatException('samples must be an array');
      final values = rawSamples
          .map((raw) {
            if (raw is! Map)
              throw const FormatException('baseline sample must be an object');
            final day = DateTime.parse(raw['day'] as String);
            return MapEntry(
                day,
                raw['value'] == null
                    ? null
                    : _number(raw['value'], 'sample.value'));
          })
          .where((entry) => entry.key.isBefore(target))
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final result = Baselines.foldHistory(
          values.map((entry) => entry.value).toList(growable: false),
          _metricCfg(input['configuration'] as String? ?? 'hrv'));
      return {
        ...result.toJson(),
        'present': result.nValid > 0,
        'algorithm_version': 'ana02.baseline.v1'
      };
    case 'hrvTime':
      final result = hrvTime(
          _numbers(input['nn_ms'] ?? input['rr_ms'], 'nn_ms'),
          nnTimesMs: input['nn_times_ms'] == null
              ? null
              : _numbers(input['nn_times_ms'], 'nn_times_ms'));
      return _metricJson(
          result, 'ana02.hrv.v1', (value) => (value as HrvTime).toJson());
    case 'nocturnalRmssd':
      final result = nocturnalRmssd(_numbers(input['nn_ms'], 'nn_ms'),
          _numbers(input['nn_times_ms'], 'nn_times_ms'),
          windowMs: input['window_ms'] == null
              ? 300000
              : _number(input['window_ms'], 'window_ms'),
          minBeatsPerWindow: input['min_beats_per_window'] == null
              ? 5
              : (input['min_beats_per_window'] as num).toInt(),
          stageMaskPerSec: _optionalBools(
              input['stage_mask_per_sec'], 'stage_mask_per_sec'));
      return _metricJson(result, 'ana02.hrv.v1');
    case 'sleepSessionWindowedRmssd':
      final result = sleepSessionWindowedRmssd(
          _numbers(input['rr_ms'], 'rr_ms'),
          _numbers(input['rr_ts_ms'], 'rr_ts_ms'),
          startSec: (input['start_sec'] as num).toInt(),
          endSec: (input['end_sec'] as num).toInt(),
          windowSec: input['window_sec'] == null
              ? 300
              : (input['window_sec'] as num).toInt());
      return _metricJson(result, 'ana02.hrv.v1');
    case 'hrvFreq':
      final result = hrvFreq(_numbers(input['nn_ms'], 'nn_ms'),
          _numbers(input['nn_times_ms'], 'nn_times_ms'),
          artifactFraction:
              _number(input['artifact_fraction'], 'artifact_fraction'),
          hfArtifactGate: input['hf_artifact_gate'] == null
              ? 0.15
              : _number(input['hf_artifact_gate'], 'hf_artifact_gate'),
          gridPoints: input['grid_points'] == null
              ? 600
              : (input['grid_points'] as num).toInt());
      return _metricJson(
          result, 'ana02.hrv.v1', (value) => (value as HrvFreq).toJson());
    case 'nocturnalRhr':
      final result = nocturnalRhr(_numbers(input['hr'], 'hr'),
          windowSamples: input['window_samples'] == null
              ? 1800
              : (input['window_samples'] as num).toInt(),
          minCoverage: input['min_coverage'] == null
              ? 0.9
              : _number(input['min_coverage'], 'min_coverage'));
      return _metricJson(result, 'ana02.nocturnal.v1',
          (value) => (value as NocturnalRhr).toJson());
    case 'dailyNocturnalRhr':
      return _dailyNocturnalRhrJson(input);
    case 'hrDip':
      final result = hrDip(_numbers(input['day_hr'], 'day_hr'),
          _numbers(input['night_hr'], 'night_hr'),
          minSamples: input['min_samples'] == null
              ? hrDipMinSamples
              : (input['min_samples'] as num).toInt());
      return _metricJson(
          result, 'ana02.nocturnal.v1', (value) => (value as HrDip).toJson());
    case 'rsaRespRate':
      final result = rsaRespRate(_numbers(input['nn_ms'], 'nn_ms'),
          _numbers(input['nn_times_ms'], 'nn_times_ms'),
          artifactFraction:
              _number(input['artifact_fraction'], 'artifact_fraction'),
          agreeBrpm: input['agree_brpm'] == null
              ? 3
              : _number(input['agree_brpm'], 'agree_brpm'),
          maxArtifact: input['max_artifact'] == null
              ? 0.3
              : _number(input['max_artifact'], 'max_artifact'));
      return _metricJson(result, 'ana02.respiration.v1',
          (value) => (value as RespEstimate).toJson());
    case 'riivRespRate':
      final result = riivRespRate(
          _numbers(input['adc'], 'adc'), _numbers(input['ts_sec'], 'ts_sec'),
          validFraction: input['valid_fraction'] == null
              ? 1
              : _number(input['valid_fraction'], 'valid_fraction'));
      return _metricJson(result, 'ana02.respiration.v1',
          (value) => (value as RespEstimate).toJson());
    case 'fuseRespRate':
      final rsa = _decodeRespMetric(input['rsa'] as Map, 'rsa');
      final riiv = _decodeRespMetric(input['riiv'] as Map, 'riiv');
      final result = fuseRespRate(rsa, riiv,
          sdGateBrpm: input['sd_gate_brpm'] == null
              ? 5
              : _number(input['sd_gate_brpm'], 'sd_gate_brpm'));
      return _metricJson(result, 'ana02.respiration.v1',
          (value) => (value as FusedResp).toJson());
    case 'breathingRateVariability':
      final result = breathingRateVariability(_numbers(input['brpm'], 'brpm'));
      return _metricJson(result, 'ana02.respiration.v1',
          (value) => (value as BrvResult).toJson());
    case 'sleepCardioClassify':
      return _sleepCardioJson(input);
    case 'sleepSegmentation':
      return _sleepSegmentationJson(input);
    case 'sleepHRFallback':
      return _sleepFallbackJson(input);
    case 'sleepAccounting':
      return _sleepAccountingJson(input);
    case 'sleepRegularity':
      return _sleepRegularityJson(input);
    case 'sleepHypnogram':
      return _sleepHypnogramJson(input);
    case 'sleepDayAssignment':
      return _sleepDayAssignmentJson(input);
    case 'readinessComposite':
      return _readinessJson(input);
    case 'stressIndex':
      return _stressJson(input);
    case 'anomaly':
      return _anomalyJson(input);
    case 'changePoint':
    case 'changepoint':
      return _changePointJson(input);
    case 'illnessCusum':
      return _illnessCusumJson(input);
    case 'staticTilt':
      return _staticTiltJson(input);
    case 'energyFusion':
      return _energyFusionJson(input);
    case 'stepCounterReconcile':
      return _stepCounterJson(input);
    case 'workoutDetect':
      return _workoutDetectJson(input);
    case 'hrRecovery':
      return _hrRecoveryJson(input);
    case 'dayCurves':
      return _dayCurvesJson(input);
    case 'boutCalories':
      return _boutCaloriesJson(input);
    case 'dailyEnergy':
      return _dailyEnergyJson(input);
    default:
      throw FormatException('unsupported metric: $metric');
  }
}

Metric<RespEstimate> _decodeRespMetric(Map input, String label) {
  final absent =
      input['value'] == null || input['value'] == '—' || input['value'] is! Map;
  final inputs =
      (input['inputs_used'] as List?)?.cast<String>() ?? const <String>[];
  final confidence = input['confidence'] == null
      ? 0.0
      : _number(input['confidence'], '$label.confidence');
  final tier = Tier.all.contains(input['tier'])
      ? input['tier'] as String
      : Tier.relative;
  if (absent)
    return Metric<RespEstimate>.absent(
        tier: tier, inputs_used: inputs, note: input['note'] as String?);
  final value = input['value'] as Map;
  return Metric(
      value: RespEstimate(
          _nullableNum(value['brpm']),
          _nullableNum(value['peak_hz']),
          _nullableNum(value['power']),
          value['source'] as String? ?? label),
      confidence: confidence,
      tier: tier,
      inputs_used: inputs,
      note: input['note'] as String?);
}

double? _nullableNum(Object? value) => value is num ? value.toDouble() : null;

MetricCfg _metricCfg(String name) {
  switch (name) {
    case 'resting_hr':
      return Baselines.restingHRCfg;
    case 'resp':
      return Baselines.respCfg;
    case 'skin_temp':
      return Baselines.skinTempCfg;
    case 'hrv':
      return Baselines.hrvCfg;
    default:
      throw FormatException('unknown baseline configuration: $name');
  }
}

BaselineState _decodeBaseline(Map state) {
  final status = BaselineStatus.values
      .firstWhere((candidate) => candidate.name == state['status']);
  return BaselineState(
      baseline: _number(state['baseline'], 'state.baseline'),
      spread: _number(state['spread'], 'state.spread'),
      nValid: (state['n_valid'] as num).toInt(),
      nightsSinceUpdate: (state['nights_since_update'] as num).toInt(),
      status: status);
}

void main(List<String> args) {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage());
    return;
  }
  if (args.length != 1) {
    stderr.writeln(_usage());
    exitCode = 64;
    return;
  }
  try {
    final decoded = jsonDecode(File(args.single).readAsStringSync());
    if (decoded is! Map)
      throw const FormatException('fixture root must be an object');
    final result = _run(Map<String, dynamic>.from(decoded));
    stdout.write(jsonEncode(_sortJson(result)));
  } on Object catch (error) {
    stderr.writeln('parity_runner: $error');
    exitCode = 65;
  }
}

Object? _sortJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _sortJson(value[key])
    };
  }
  if (value is List) return value.map(_sortJson).toList(growable: false);
  if (value is double && (value.isNaN || value.isInfinite)) return null;
  return value;
}
