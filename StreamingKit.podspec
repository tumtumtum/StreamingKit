Pod::Spec.new do |s|
  s.name         = "StreamingKit"
  s.version      = "0.1.31"
  s.platform     = :ios
  s.ios.deployment_target = '5.0'
  s.osx.deployment_target = '10.7'
  s.summary      = "A fast and extensible audio streamer for iOS and OSX with support for gapless playback and custom (non-HTTP) sources."
  s.homepage     = "https://github.com/tumtumtum/StreamingKit/"
  s.license      = 'MIT'
  s.author       = { "Thong Nguyen" => "tumtumtum@gmail.com" }
  s.source       = { :git => "https://github.com/tumtumtum/StreamingKit.git", :tag => s.version.to_s}
  s.requires_arc = true
  s.source_files = 'StreamingKit/StreamingKit/*.{h,m}'
  s.ios.frameworks   = 'SystemConfiguration', 'CFNetwork', 'CoreFoundation', 'AudioToolbox'
  s.osx.frameworks   = 'SystemConfiguration', 'CFNetwork', 'CoreFoundation', 'AudioToolbox', 'AudioUnit'
end
