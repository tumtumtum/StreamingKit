## StreamingKit

StreamingKit (formally Audjustable) is an audio playback and streaming library for iOS and Mac OSX.  StreamingKit uses CoreAudio to decompress and playback audio (using hardware or software codecs) whilst providing a clean and simple object-oriented API.

The primary motivation of this project was to decouple the input data sources from the actual player logic in order to allow advanced customizable input handling such as HTTP streaming, encryption/decryption, auto-recovery, dynamic-buffering. StreamingKit is the only streaming and playback library that supports dead-easy [gapless playback](https://github.com/tumtumtum/StreamingKit/wiki/Gapless-playback) between audio files of differing formats.

## Main Features

* Simple OOP API.
* Easy to read source.
* Mostly asynchronous API.
* Buffered and gapless playback between all format types.
* Easy to implement audio data sources (Local, HTTP, Auto Recovering HTTP DataSources are provided).
* Easy to extend DataSource to support adaptive buffering, encryption, etc.
* Optimised for low CPU/battery usage.
* Optimised for linear data sources. Random access sources are required only for seeking.
* Example apps iOS and Mac OSX provided.
* StreamingKit 0.2.0 uses the AudioUnit API rather than the slower AudioQueues API which allows real-time interception of the raw PCM data for features such as level metering, EQ, etc.

## Installation

StreamingKit is available as a [Cocoapod](http://cocoapods.org/?q=StreamingKit). You can also simply copy all the source files located inside StreamingKit/StreamingKit/* into your Xcode project.

## Example

There are two main classes.  The `STKDataSource` class which is the abstract base class for the various compressed audio data sources. The `STKAudioPlayer` class manages and renders audio from a queue DataSources. By default `STKAudioPlayer` will automatically parse URLs and create the appropriate data source internally.

### Play an MP3 over HTTP



```objective-c
STKAudioPlayer* audioPlayer = [[STKAudioPlayer alloc] init];
audioPlayer.delegate = self;

[audioPlayer play:@"http://fs.bloom.fm/oss/audiosamples/sample.mp3"];
```


### Intercept PCM data just before its played

```objective-c
[audioPlayer appendFrameFilterWithName:@"MyCustomFilter" block:^(UInt32 channelsPerFrame, UInt32 bytesPerFrame, UInt32 frameCount, void* frames)
{
   ...
}];
````


## More

More documentation is available on the project [Wiki](https://github.com/tumtumtum/StreamingKit/wiki)

### Authors and Contributors
Copyright (c) 2012-2014, Thong Nguyen ([@tumtumtum](http://www.twitter.com/tumtumtum))
