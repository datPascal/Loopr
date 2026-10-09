import 'dart:convert';
import 'dart:io';

import '../../OpenStrap Code/analytics/lib/onehz.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: strain_score_metric_runner.dart INPUT_JSON');
    exitCode = 64;
    return;
  }
  final input = jsonDecode(File(args.single).readAsStringSync()) as Map;
  if (input['metric'] != 'strainScoreMetric' || input['trimp'] != 335) {
    stderr.writeln('unexpected fixture input');
    exitCode = 65;
    return;
  }
  stdout.write(jsonEncode(strainScoreMetric((input['trimp'] as num).toDouble()).toJson()));
}
