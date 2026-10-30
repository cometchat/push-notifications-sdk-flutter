#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint cometchat_voip.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'cometchat_voip'
  s.version          = '2.0.0'
  s.summary          = 'CometChat VoIP call notifications for Flutter.'
  s.description      = <<-DESC
Incoming CometChat calls on iOS: the package owns the PushKit registry, reports
every VoIP push to CallKit, connects the call while it rings, and hands Answer
and Decline to the Calls SDK.
                       DESC
  s.homepage         = 'https://www.cometchat.com'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'CometChat' => 'dev@cometchat.com' }
  s.source           = { :path => '.' }
  s.source_files = 'cometchat_voip/Sources/cometchat_voip/**/*.swift'
  s.resource_bundles = {'cometchat_voip_privacy' => ['cometchat_voip/Sources/cometchat_voip/Resources/PrivacyInfo.xcprivacy']}
  s.dependency 'Flutter'
  # No Calls SDK here. This package depends on `cometchat_calls_sdk` and
  # nothing else; everything needing it goes back to Dart through
  # DartCallsBridge. The CXProvider is OURS — see CallKitManager. An app still
  # points its Podfile at the podspec cometchat_calls_sdk ships, because that
  # package needs it; see the README.
  s.frameworks = 'PushKit', 'CallKit', 'AVFoundation', 'UIKit'
  s.platform = :ios, '15.1'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
