import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:webrtc_interface/webrtc_interface.dart';

import '../../events.dart';
import '../../logger.dart';
import '../../proto/livekit_models.pb.dart' as lk_models;
import '../../proto/livekit_rtc.pb.dart' as lk_rtc;
import '../../publication/local.dart';
import '../../types/other.dart';
import '../../utils.dart';
import '../options.dart';
import '../stats.dart';
import 'audio.dart';
import 'local.dart';

class SimulcastTrackInfo {
  String codec;

  rtc.MediaStreamTrack mediaStreamTrack;

  rtc.RTCRtpSender? sender;

  List<rtc.RTCRtpEncoding>? encodings;

  SimulcastTrackInfo(
      {required this.codec,
      this.encodings,
      required this.mediaStreamTrack,
      this.sender});
}

/// A video track from the local device. Use static methods in this class to create
/// video tracks.
class LocalVideoTrack extends LocalTrack with VideoTrack {
  // Options used for this track
  @override
  covariant VideoCaptureOptions currentOptions;

  num? _currentBitrate;
  get currentBitrate => _currentBitrate;
  Map<String, VideoSenderStats>? prevStats;
  final Map<String, num> _bitrateFoLayers = {};

  lk_models.VideoCodec? videoCodec;

  Map<String, SimulcastTrackInfo> simulcastCodecs = {};

  List<lk_rtc.SubscribedCodec> subscribedCodecs = [];

  @override
  Future<bool> monitorStats() async {
    if (sender == null || events.isDisposed) {
      _currentBitrate = 0;
      return false;
    }
    List<VideoSenderStats> stats = [];
    try {
      stats = await getSenderStats();
    } catch (e) {
      logger.warning('Failed to get sender stats: $e');
      return false;
    }
    Map<String, VideoSenderStats> statsMap = {};

    for (var s in stats) {
      statsMap[s.rid ?? 'f'] = s;
    }

    if (prevStats != null) {
      num totalBitrate = 0;
      statsMap.forEach((key, s) {
        final prev = prevStats![key];
        var bitRateForlayer = computeBitrateForSenderStats(s, prev).toInt();
        _bitrateFoLayers[key] = bitRateForlayer;
        totalBitrate += bitRateForlayer;
      });
      _currentBitrate = totalBitrate;
      events.emit(VideoSenderStatsEvent(
        stats: statsMap,
        currentBitrate: currentBitrate,
        bitrateForLayers: _bitrateFoLayers,
      ));
    }

    prevStats = statsMap;
    return true;
  }

  Future<List<VideoSenderStats>> getSenderStats() async {
    if (sender == null) {
      return [];
    }

    final stats = await sender!.getStats();
    List<VideoSenderStats> items = [];
    for (var v in stats) {
      if (v.type == 'outbound-rtp') {
        VideoSenderStats vs = VideoSenderStats(v.id, v.timestamp);
        vs.frameHeight = getNumValFromReport(v.values, 'frameHeight');
        vs.frameWidth = getNumValFromReport(v.values, 'frameWidth');
        vs.framesPerSecond = getNumValFromReport(v.values, 'framesPerSecond');
        vs.firCount = getNumValFromReport(v.values, 'firCount');
        vs.pliCount = getNumValFromReport(v.values, 'pliCount');
        vs.nackCount = getNumValFromReport(v.values, 'nackCount');
        vs.packetsSent = getNumValFromReport(v.values, 'packetsSent');
        vs.bytesSent = getNumValFromReport(v.values, 'bytesSent');
        vs.framesSent = getNumValFromReport(v.values, 'framesSent');
        vs.rid = getStringValFromReport(v.values, 'rid');
        vs.encoderImplementation =
            getStringValFromReport(v.values, 'encoderImplementation');
        vs.retransmittedPacketsSent =
            getNumValFromReport(v.values, 'retransmittedPacketsSent');
        vs.qualityLimitationReason =
            getStringValFromReport(v.values, 'qualityLimitationReason');
        vs.qualityLimitationResolutionChanges =
            getNumValFromReport(v.values, 'qualityLimitationResolutionChanges');

        // locate the appropriate remote-inbound-rtp item
        final remoteId = getStringValFromReport(v.values, 'remoteId');
        final r = stats.firstWhereOrNull((element) => element.id == remoteId);
        if (r != null) {
          vs.jitter = getNumValFromReport(r.values, 'jitter');
          vs.packetsLost = getNumValFromReport(r.values, 'packetsLost');
          vs.roundTripTime = getNumValFromReport(r.values, 'roundTripTime');
        }
        final c = stats.firstWhereOrNull((element) => element.type == 'codec');
        if (c != null) {
          vs.mimeType = getStringValFromReport(c.values, 'mimeType');
          vs.payloadType = getNumValFromReport(c.values, 'payloadType');
          vs.channels = getNumValFromReport(c.values, 'channels');
          vs.clockRate = getNumValFromReport(c.values, 'clockRate');
        }
        items.add(vs);
      }
    }
    return items;
  }

  // Private constructor
  LocalVideoTrack._(
    TrackSource source,
    rtc.MediaStream stream,
    rtc.MediaStreamTrack track,
    this.currentOptions,
  ) : super(
          lk_models.TrackType.VIDEO,
          source,
          stream,
          track,
        );

  /// Creates a LocalVideoTrack from camera input.
  static Future<LocalVideoTrack> createCameraTrack([
    CameraCaptureOptions? options,
  ]) async {
    options ??= const CameraCaptureOptions();

    final stream = await LocalTrack.createStream(options);
    return LocalVideoTrack._(
      TrackSource.camera,
      stream,
      stream.getVideoTracks().first,
      options,
    );
  }

  /// Creates a LocalVideoTrack from the display.
  ///
  /// Note: Android requires a foreground service to be started prior to
  /// creating a screen track. Refer to the example app for an implementation.
  static Future<LocalVideoTrack> createScreenShareTrack([
    ScreenShareCaptureOptions? options,
  ]) async {
    options ??= const ScreenShareCaptureOptions();

    final stream = await LocalTrack.createStream(options);
    return LocalVideoTrack._(
      TrackSource.screenShareVideo,
      stream,
      stream.getVideoTracks().first,
      options,
    );
  }

  /// Creates a LocalTracks(audio/video) from the display.
  ///
  /// The current API is mainly used to capture audio when chrome captures tab,
  /// but in the future it can also be used for flutter native to open audio
  /// capture device when capturing screen
  static Future<List<LocalTrack>> createScreenShareTracksWithAudio([
    ScreenShareCaptureOptions? options,
  ]) async {
    if (options == null) {
      options = const ScreenShareCaptureOptions(captureScreenAudio: true);
    } else {
      options = options.copyWith(captureScreenAudio: true);
    }
    final stream = await LocalTrack.createStream(options);

    List<LocalTrack> tracks = [
      LocalVideoTrack._(
        TrackSource.screenShareVideo,
        stream,
        stream.getVideoTracks().first,
        options,
      )
    ];

    if (stream.getAudioTracks().isNotEmpty) {
      tracks.add(LocalAudioTrack(TrackSource.screenShareAudio, stream,
          stream.getAudioTracks().first, const AudioCaptureOptions()));
    }
    return tracks;
  }
}

//
// Convenience extensions
//
extension LocalVideoTrackExt on LocalVideoTrack {
  // Calls restartTrack under the hood
  Future<void> setCameraPosition(CameraPosition position) async {
    final options = currentOptions;
    if (options is! CameraCaptureOptions) {
      logger.warning('Not a camera track');
      return;
    }
    final newOptions = CameraCaptureOptions(
        cameraPosition: position,
        deviceId: null,
        maxFrameRate: options.maxFrameRate,
        params: options.params);
    await restartTrack(newOptions);
    currentOptions = newOptions;
  }

  Future<void> switchCamera(String deviceId, {bool fastSwitch = false}) async {
    final options = currentOptions;
    if (options is! CameraCaptureOptions) {
      logger.warning('Not a camera track');
      return;
    }

    if (fastSwitch) {
      currentOptions = options.copyWith(deviceId: deviceId);
      await rtc.Helper.switchCamera(mediaStreamTrack, deviceId, mediaStream);
      return;
    }

    await restartTrack(
      options.copyWith(deviceId: deviceId),
    );
  }

  Future<List<lk_models.VideoCodec>> setPublishingCodecs(
      List<lk_rtc.SubscribedCodec> codecs,
      LocalTrackPublication publication) async {
    logger.fine('setPublishingCodecs $codecs');

    // only enable simulcast codec for preference codec setted
    if (videoCodec == null && codecs.isNotEmpty) {
      publication.updatePublishingLayers(codecs[0].qualities);
      return [];
    }

    subscribedCodecs = codecs;

    List<lk_models.VideoCodec> newCodecs = [];

    for (var codec in codecs) {
      if (videoCodec == null || videoCodec?.name == codec.codec) {
        publication.updatePublishingLayers(codec.qualities);
      } else {
        final simulcastCodecInfo = simulcastCodecs[codec.codec];
        logger.fine('setPublishingCodecs $codecs');
        if (simulcastCodecInfo == null || simulcastCodecInfo.sender == null) {
          for (var q in codec.qualities) {
            if (q.enabled) {
              newCodecs.add(codec.codec as lk_models.VideoCodec);
              break;
            }
          }
        } else if (simulcastCodecInfo.encodings != null) {
          logger.fine('setPublishingCodecs $codecs');
          await setPublishingLayersForSender(
            simulcastCodecInfo.sender!,
            simulcastCodecInfo.encodings!,
            codec.qualities,
          );
        }
      }
    }
    return newCodecs;
  }

  Future<void> setPublishingLayersForSender(
      RTCRtpSender sender,
      List<RTCRtpEncoding> encodings,
      List<lk_rtc.SubscribedQuality> qualities) async {}

  SimulcastTrackInfo addSimulcastTrack(
      String codec, List<RTCRtpEncoding> encodings) {
    if (simulcastCodecs[codec] != null) {
      throw Exception('$codec already added');
    }
    SimulcastTrackInfo simulcastCodecInfo = SimulcastTrackInfo(
        codec: codec, encodings: encodings, mediaStreamTrack: mediaStreamTrack);

    simulcastCodecs[codec] = simulcastCodecInfo;
    return simulcastCodecInfo;
  }

  void setSimulcastTrackSender(
      String codec, RTCRtpSender sender, LocalTrackPublication publication) {
    var simulcastCodecInfo = simulcastCodecs[codec];
    if (simulcastCodecInfo == null) {
      return;
    }
    simulcastCodecInfo.sender = sender;

    // browser will reenable disabled codec/layers after new codec has been published,
    // so refresh subscribedCodecs after publish a new codec
    Future.delayed(
        const Duration(milliseconds: refreshSubscribedCodecAfterNewCodec), () {
      if (subscribedCodecs.isNotEmpty) {
        setPublishingCodecs(subscribedCodecs, publication);
      }
    });
  }
}
