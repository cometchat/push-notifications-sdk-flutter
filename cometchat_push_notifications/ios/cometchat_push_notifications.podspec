#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint cometchat_push_notifications.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'cometchat_push_notifications'
  s.version          = '2.0.0'
  s.summary          = 'CometChat chat push notifications for Flutter.'
  s.description      = <<-DESC
Chat push notifications for CometChat-powered Flutter apps: foreground
presentation, notification taps, quick reply and badge handling.
                       DESC
  s.homepage         = 'https://www.cometchat.com'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'CometChat' => 'dev@cometchat.com' }
  s.source           = { :path => '.' }
  s.source_files = 'cometchat_push_notifications/Sources/cometchat_push_notifications/**/*.swift'
  s.resource_bundles = {'cometchat_push_notifications_privacy' => ['cometchat_push_notifications/Sources/cometchat_push_notifications/Resources/PrivacyInfo.xcprivacy']}
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

end
