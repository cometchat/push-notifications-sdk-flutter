#
# The Notification Service Extension half of cometchat_push_notifications.
#
# An extension is a separate process with no Flutter engine, so it cannot be
# reached through the Flutter plugin and is a pod of its own. Add it to the
# extension target only — never to the app target, which has the plugin already:
#
#   target 'NotificationService' do
#     pod 'CometChatPushNotificationsNSE',
#         :path => '.symlinks/plugins/cometchat_push_notifications/ios'
#   end
#
Pod::Spec.new do |s|
  s.name             = 'CometChatPushNotificationsNSE'
  s.version          = '2.0.0'
  s.summary          = 'Notification Service Extension support for CometChat push notifications.'
  s.description      = <<-DESC
The base class a Notification Service Extension subclasses to give CometChat
chat notifications delivery receipts, the sender's avatar, conversation
grouping and plain-text bodies. Companion to the cometchat_push_notifications
Flutter plugin.
                       DESC
  s.homepage         = 'https://www.cometchat.com'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'CometChat' => 'dev@cometchat.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'CometChatPushNotificationsNSE/Sources/**/*.swift'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'

  # Delivery receipts go through the Chat SDK; everything else here is
  # Foundation. Deliberately no Flutter dependency: an extension has no engine.
  s.dependency 'CometChatSDK', '~> 4.1'

  # An extension cannot link UIKit's app-only APIs.
  s.pod_target_xcconfig = {
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
