# The Flutter plugin's iOS side: a bridge to the Kirora iOS SDK (kirora-ios), which does the work.
# Until Kirora 0.1.0 is published, the app's Podfile points the Kirora pod at a local copy:
#   pod 'Kirora', :path => '../path/to/kirora-ios'
Pod::Spec.new do |s|
  s.name             = 'kirora_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Kirora client SDK for Flutter: events, visits, consent and push.'
  s.homepage         = 'https://www.kirora.io'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Kirora'
  s.source           = { :path => '.' }
  s.source_files     = 'kirora_flutter/Sources/kirora_flutter/**/*.swift'
  s.dependency 'Flutter'
  s.dependency 'Kirora', '0.1.0'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
