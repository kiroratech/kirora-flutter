# The Flutter plugin's iOS side: a bridge to the Kirora iOS SDK (kirora-ios), which does the work.
# The SDK's sources are bundled in Kirora/ (tool/sync_kirora_ios.sh) and built into this pod, so
# nothing comes from CocoaPods trunk. Swift Package Manager builds use Package.swift instead.
Pod::Spec.new do |s|
  s.name             = 'kirora_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Kirora client SDK for Flutter: events, visits, consent and push.'
  s.homepage         = 'https://www.kirora.io'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Kirora'
  s.source           = { :path => '.' }
  s.source_files     = 'kirora_flutter/Sources/kirora_flutter/**/*.swift', 'Kirora/Sources/Kirora/**/*.swift'
  s.resource_bundles = { 'Kirora_Privacy' => ['Kirora/Sources/Kirora/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'UIKit', 'UserNotifications'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) KIRORA_BUNDLED',
  }
end
