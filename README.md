# FFMPEGMediaExtension

This is an attempt to build a macOS 15.0 MediaExtension for libAV* which in theory would allow for native AVFoundation container parsing and decode of FFMPEG enabled Container formats (.mkv, .wmv, .avi etc) and Codecs (ie VP9, VP8, DIVX, XVID etc).

You can think of Media Extensions as a modern macOS replacement for old macOS 7, 8, 9 and early macOS X Quicktime Extensions.

You can think of this project as an attempt to make a one size fits all Media Extension like the old Perian software.

Since Media Extensions are shipped in a host app, this has also provides a Host app.

We have h264 GOP decode from an MKV container working! 

<video src="https://github.com/user-attachments/assets/4cdaf21f-120c-4793-8453-4dd9b4810916">


But there is a ton left to do!
- [ ] Asset / Track Metadata
- [ ] GOP Support
- [ ] Additional Codecs

## Goal

Provide additional media format playback support for any macOS app which leverages AVFoundation / Core Media as its underlying playback / decode engine

* Finder
* Quicklook
* Quicktime Player
* Any other app which opts in by calling:
    * `MTRegisterProfessionalVideoWorkflowFormatReaders()` for format parsing support
    * `VTRegisterProfessionalVideoWorkflowVideoDecoders()` for additional decoder support


## Requirements:

* MacOS 15 Beta 4 + 
* XCode 16 Beta 4 + 

## Building:

If you want to build FFMPEG libAVFormat and libAVCodec:

`brew install automake nasm pkg-config`

FFMPEG is installed as a submodule - so ensure you git checkout the submodule and init

`cd ffmpeg`
```
./configure --prefix=/usr/local --enable-static --disable-shared --disable-programs --disable-doc --disable-avdevice --disable-avfilter --disable-postproc --disable-swscale --disable-swresample --arch=arm64 --disable-avfoundation
```

`make -j$(sysctl -n hw.ncpu)`

This will build you the statically linked libAVFormat.a and libAVCodec.a libries 

## Design

MEFormatReader (LibAVFOrmatReader)
* [x] Plugin instantiation via `LibAVFormatReaderFactory`
* [x] Register a limited number of supported container formats via plist / exported content types
    * [x] MKV
    * Adding new Containers requires editing multiple annoying Plist entries
* [x] Basic Container parsing via libavformat (`LibAVFormatReader`)
* [ ] Container metadata to AVMetadataItems
* [x] Track Parsing (Audio and Video only right now) (`LibAVTrackReader`)
* [ ] Track specific metadata to AVMEtadataItems
* [x] CMFormatDescriptions for our Tracks
* [x] Seek / Stepping via `LibAVSampleCursor`
* [ ] Provide additional sample metadata that some formats require
    * [ ] Sample Sync info
    * [ ] Sample Dependency info
    * [ ] Post Decode Processing Data 

MEVideoDecoder
* Not yet started
* This means today we only add container support, not yet additional codecs
* Stay tuned

## Todo:

* [x] libavformat / libavcodec, libavutil compiled as a .a
* [x] ffmpeg headers inlcuded
* [x] Swift Modulemap + Obj-C libav*
* [ ] Implement necessary Media Extension protocols
    * [x] MEFormatReaderExtension
    * [x] MEFormatReader (partial)
    * [x] METrackReader
    * [x] METrackInfo
    * [x] MESampleCursor (partial)
    * [ ] MEVideoDecoderExtension
    * [ ] MEVideoDecoder
    * [ ] MEVideoDecoderPixelBufferManager
* [x] impelment Extension requirements (plists, entitlements, etc)
* [ ] Memory Management pass in ObjC / C 

## Strategy

We Eventually require 2 Bundle targets that are Media Extensions.

* A Media Extention that implements `MEFormatReader`, which will allow container parsing via `libavformat` and provide container metadata, track metadata, and compressed sample metadata. 

* A Media Extension that impelments `MEVideoDecoder` - a Video Decompressor which will allow for codec decompression via `libavcodec` and provide pixel buffers from appropriate samples. 


FFMPEGs library more or less follows similar design patterns to AVFoundation. The following isnt totally accurate, but more or less gets the point across:

* `CMTime` <~> `AVRational` 
* `CMMediaType` <~> `AVMediaType`
* `CMFormatDescription` <~> `AVCodecParameters`
* `CMSampleBuffer` <~> `AVPacket`
* `CMBlockBuffer` <~> `AVBuffer`
* `CVPixelBuffer` <-> `AVFrame` (decoded video)

* `AVAsset` <~> `AVFormatContext`
* `AVAssetTrack` <~> `AVStream`
* `AVSampleCursor` <~> `AVIOContext` 




Leverage AVIOContext to allow a MEByteSource to driven by a AVFormatContext to get us container parsing and metadata

## Running Notes:

* Weirdly MediaExtension headers imply macOS 14 supported?
* entitlements for Media Extensions
