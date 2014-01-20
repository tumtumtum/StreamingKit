## StreamingKit

StreamingKit (formally Audjustable) is an audio streaming library for iOS and OSX.  StreamingKit uses CoreAudio to decompress and playback audio whilst providing a clean and simple object-oriented API.

The primary motivation of this project was to decouple the input data sources from the actual player logic in order to allow advanced customizable input handling such as HTTP streaming, encryption/decryption, auto-recovery, dynamic-buffering. Along the way other features such as gapless playback were added.

## Main Features

* Simple OOP API
* Easy to read source
* Mostly asynchronous API
* Buffered and gapless playback
* Easy to implement audio data sources (Local, HTTP, Auto Recovering HTTP DataSources are provided)
* Easy to extend DataSource to support adaptive buffering, encryption, etc.
* Optimised for low CPU/battery usage

## Installation

StreamingKit is also available as a [Cocoapod](http://cocoapods.org/?q=StreamingKit) and a static lib. You can also simply manually copy all the source files located inside StreamingKit/StreamingKit/* into your project.

## Example

There are two main classes.  The `STKDataSource` class which is the abstract base class for the various compressed audio data sources. The `STKAudioPlayer` class manages and renders audio from a queue DataSources. By default `STKAudioPlayer` will automatically parse URLs and create the appropriate data source internally.

```objective-c

// Create AudioPlayer

STKAudioPlayer* audioPlayer = [[STKAudioPlayer alloc] init];
audioPlayer.delegate = self;

[audioPlayer play:@"http://fs.bloom.fm/oss/audiosamples/sample.mp3"];


```

## More

More documentation is available on the project [wiki](https://github.com/tumtumtum/StreamingKit/wiki)

### Authors and Contributors
Copyright (c) 2012-2014, Thong Nguyen (@tumtumtum)
