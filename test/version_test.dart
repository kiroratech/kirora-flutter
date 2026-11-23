import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirora_flutter/src/version.dart';

String _match(String path, String pattern) =>
    RegExp(pattern, multiLine: true).firstMatch(File(path).readAsStringSync())!.group(1)!;

void main() {
  test('the version reported to Kirora is the package version', () {
    expect(sdkVersion, _match('pubspec.yaml', r'^version:\s*(\S+)'));
  });

  test('CocoaPods bundles the kirora-ios version Swift Package Manager pins', () {
    // Refresh the bundled copy with tool/sync_kirora_ios.sh <tag>.
    expect(
      _match('ios/Kirora/Sources/Kirora/Internal/Support.swift', r'^let sdkVersion = "([^"]+)"'),
      _match('ios/kirora_flutter/Package.swift', r'kirora-ios\.git", exact: "([^"]+)"'),
    );
  });
}
