#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint native_app_bars.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'native_app_bars'
  s.version          = '0.1.0-dev.10'
  s.summary          = 'Native UINavigationBar/UITabBar host for the native_app_bars Flutter package.'
  s.description      = <<-DESC
Hosts the Flutter view controller once and shows standalone UINavigationBar and UITabBar siblings driven from Dart.
                       DESC
  s.homepage         = 'https://github.com/tsleedev/native_app_bars'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'TaeSu Lee'
  # Flutter uses a local pod path. A remote CocoaPods source uses the version tag.
  s.source           = { :git => "#{s.homepage}.git", :tag => s.version.to_s }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '16.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = { 'native_chrome_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
