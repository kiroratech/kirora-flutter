import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirora_flutter/src/version.dart';

void main() {
  test('the version reported to Kirora is the package version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(sdkVersion, version);
  });
}
