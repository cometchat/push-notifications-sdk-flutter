#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint cometchat_notifications.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'cometchat_push_notifications'
  s.version          = '1.0.1'
  s.summary          = 'CometChat push notifications and VoIP calling for Flutter.'
  s.description      = <<-DESC
CometChat push notifications (FCM / APNs) and VoIP calling for Flutter.
                       DESC
  s.homepage         = 'https://www.cometchat.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CometChat' => 'dev@cometchat.com' }
  s.source           = { :path => '.' }
  s.source_files = 'cometchat_push_notifications/Sources/cometchat_push_notifications/**/*.swift'
  s.resource_bundles = {'cometchat_push_notifications_privacy' => ['cometchat_push_notifications/Sources/cometchat_push_notifications/Resources/PrivacyInfo.xcprivacy']}
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'cometchat_push_notifications_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
