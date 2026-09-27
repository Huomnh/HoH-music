/// Online source track download into a user-selected local folder.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/source_host.dart';
import '../../core/source/source_models.dart';
import '../library/library_pool.dart';
import '../library/library_store.dart';

class OnlineTrackDownloadService {
  OnlineTrackDownloadService({Dio? client}) : _client = client ?? Dio();

  final Dio _client;

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 HoH-music';

  Future<File> download(
    Ref ref,
    OnlineTrack track,
    String directory, {
    String? quality,
    String? outputPath,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    void Function(int received, int total, int speedBytes)? onTaskProgress,
    void Function(String path)? onResolvedPath,
  }) async {
    final SourceResolveResult resolved = await ref
        .read(sourceHostProvider.notifier)
        .resolveMusicUrl(track, quality: quality);
    if (!resolved.ok || resolved.url.isEmpty) {
      throw StateError(resolved.error.isEmpty ? '音源没有返回可下载地址' : resolved.error);
    }
    final String extension = _extension(
      resolved.url,
      resolved.resolvedQuality.isEmpty
          ? (quality ?? track.quality)
          : resolved.resolvedQuality,
      resolved.format,
    );
    final Directory target = Directory(directory);
    await target.create(recursive: true);
    final File output = outputPath == null
        ? await _availableFile(
            target,
            _safeName('${track.artist} - ${track.title}'),
            extension,
          )
        : File(outputPath);
    final File temporary = File('${output.path}.part');
    onResolvedPath?.call(output.path);
    final int existingBytes = await temporary.exists()
        ? await temporary.length()
        : 0;
    try {
      await _downloadStream(
        resolved.url,
        temporary,
        existingBytes: existingBytes,
        cancelToken: cancelToken,
        onProgress: onProgress,
        onTaskProgress: onTaskProgress,
      );
      if (!await temporary.exists() || await temporary.length() == 0) {
        throw StateError('下载结果为空');
      }
      // 音源返回的 URL 后缀不可信：不少 FLAC 地址仍然以 .mp3 或 .php 结尾。
      // 下载完成后以文件签名确认真实容器，避免出现“内容是 FLAC、文件名却是 MP3”。
      final String? detectedExtension = await _detectExtension(temporary);
      File finalOutput = output;
      if (detectedExtension != null &&
          detectedExtension != extension &&
          detectedExtension != 'unknown') {
        final String withoutExtension = output.path.replaceFirst(
          RegExp(r'\.[^./\\]+$'),
          '',
        );
        final File candidate = File('$withoutExtension.$detectedExtension');
        finalOutput = await candidate.exists()
            ? await _availableFile(
                target,
                _safeName('${track.artist} - ${track.title}'),
                detectedExtension,
              )
            : candidate;
      }
      final File saved = await temporary.rename(finalOutput.path);
      onResolvedPath?.call(saved.path);
      await _writeTags(saved, track, resolved, quality: quality);
      await ref.read(libraryProvider.notifier).addFile(saved.path);
      ref.invalidate(localLibraryProvider);
      return saved;
    } catch (error) {
      if (await temporary.exists() && cancelToken?.isCancelled != true) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  /// 用原生 HTTP 响应流写入文件，避免 Dio.download 的黑盒文件处理。
  ///
  /// 参考 LX Music 的下载器：只接受 200/206；已有临时文件时请求 Range，
  /// 服务端不支持 Range 就清空临时文件并用当前响应从头写，避免重复拼接。
  Future<void> _downloadStream(
    String url,
    File temporary, {
    required int existingBytes,
    required CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    void Function(int received, int total, int speedBytes)? onTaskProgress,
  }) async {
    final HttpClient httpClient = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = _userAgent;
    HttpClientRequest? request;
    IOSink? sink;
    try {
      request = await httpClient.getUrl(Uri.parse(url));
      request.headers
        ..set(HttpHeaders.userAgentHeader, _userAgent)
        ..set(
          HttpHeaders.acceptHeader,
          'audio/*,application/octet-stream,*/*;q=0.8',
        )
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.connectionHeader, 'keep-alive');
      if (existingBytes > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
      }

      if (cancelToken != null) {
        unawaited(
          cancelToken.whenCancel.then((_) {
            request?.abort();
          }),
        );
      }
      final HttpClientResponse response = await request.close();
      final int status = response.statusCode;
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        if (status == HttpStatus.requestedRangeNotSatisfiable &&
            existingBytes > 0) {
          if (await temporary.exists()) await temporary.delete();
          return await _downloadStream(
            url,
            temporary,
            existingBytes: 0,
            cancelToken: cancelToken,
            onProgress: onProgress,
            onTaskProgress: onTaskProgress,
          );
        }
        throw StateError('下载服务器返回 HTTP $status');
      }

      final bool append =
          existingBytes > 0 && status == HttpStatus.partialContent;
      final int offset = append ? existingBytes : 0;
      if (!append && existingBytes > 0 && await temporary.exists()) {
        await temporary.delete();
      }
      final int responseLength = response.contentLength;
      final int total = responseLength > 0 ? offset + responseLength : 0;
      int received = offset;
      int lastReceived = received;
      DateTime lastTick = DateTime.now();
      sink = temporary.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      await for (final List<int> chunk in response) {
        if (cancelToken?.isCancelled == true) {
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            error: cancelToken?.cancelError,
          );
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
        final DateTime now = DateTime.now();
        final int elapsedMs = now.difference(lastTick).inMilliseconds;
        if (elapsedMs >= 250) {
          final int speed = ((received - lastReceived) * 1000 / elapsedMs)
              .round();
          onTaskProgress?.call(received, total, speed);
          lastReceived = received;
          lastTick = now;
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total > 0 && received != total) {
        throw StateError('下载流未完整结束（$received/$total 字节）');
      }
      onProgress?.call(received, total);
      onTaskProgress?.call(received, total, 0);
    } finally {
      await sink?.close();
      httpClient.close(force: true);
    }
  }

  Future<void> _writeTags(
    File file,
    OnlineTrack track,
    SourceResolveResult resolved, {
    String? quality,
  }) async {
    try {
      Uint8List? cover;
      if (track.coverUrl.startsWith('http://') ||
          track.coverUrl.startsWith('https://')) {
        final Response<List<int>> response = await _client.get<List<int>>(
          track.coverUrl,
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        if (response.statusCode == 200 && response.data != null) {
          cover = Uint8List.fromList(response.data!);
        }
      }
      final String source = platformLabel(track.platform);
      final String selectedQuality = resolved.resolvedQuality.isEmpty
          ? (quality ?? track.quality)
          : resolved.resolvedQuality;
      final String provenance =
          'HoH music · $source · ${qualityLabel(selectedQuality)}';

      // Windows Explorer needs a real ID3v2 block at the beginning of an MP3.
      // `updateMetadata` only replaces an existing recognized tag; a bare MP3
      // can therefore remain completely untagged. Always rebuild the MP3 tag.
      if (_extensionOf(file.path) == 'mp3') {
        final Mp3Metadata metadata = Mp3Metadata()
          ..songName = track.title.isEmpty ? null : track.title
          ..leadPerformer = track.artist.isEmpty ? null : track.artist
          ..album = track.album.isEmpty ? null : track.album
          ..publisher = 'HoH music'
          ..encoderSoftware = provenance
          // 音源平台不是音乐流派；没有可靠的真实流派时保持为空。
          ..genres = <String>[];
        if (cover != null && cover.isNotEmpty) {
          metadata.pictures = <Picture>[
            Picture(cover, _imageMime(track.coverUrl), PictureType.coverFront),
          ];
        }
        Id3v4Writer().write(file, metadata);
        return;
      }

      try {
        updateMetadata(file, (metadata) {
          metadata.setTitle(track.title.isEmpty ? null : track.title);
          metadata.setArtist(track.artist.isEmpty ? null : track.artist);
          metadata.setAlbum(track.album.isEmpty ? null : track.album);
          // 不把 QQ/网易云/酷狗等平台名称写入 Genre。
          metadata.setGenres(<String>[]);
          if (cover != null && cover.isNotEmpty) {
            metadata.setPictures(<Picture>[
              Picture(
                cover,
                _imageMime(track.coverUrl),
                PictureType.coverFront,
              ),
            ]);
          }
          switch (metadata) {
            case final Mp3Metadata m:
              m.publisher = 'HoH music';
              m.encoderSoftware = provenance;
            case final Mp4Metadata _:
              // 流派未知时保持空值，不写入音源平台名称。
              break;
            case final VorbisMetadata m:
              m.encoder = <String>[provenance];
              m.comment = <String>[provenance];
            case final RiffMetadata m:
              m.encoder = provenance;
              m.comment = provenance;
            case final ApeMetadata m:
              m.comment = provenance;
          }
        });
      } catch (_) {}
    } catch (_) {}
  }

  static String _extensionOf(String path) => path.split('.').last.toLowerCase();

  /// 读取常见容器的文件签名，而不是相信音源 URL 的后缀。
  static Future<String?> _detectExtension(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final List<int> bytes = await handle.read(16);
      if (bytes.length >= 4 &&
          bytes[0] == 0x66 &&
          bytes[1] == 0x4c &&
          bytes[2] == 0x61 &&
          bytes[3] == 0x43) {
        return 'flac';
      }
      if (bytes.length >= 4 &&
          bytes[0] == 0x4f &&
          bytes[1] == 0x67 &&
          bytes[2] == 0x67 &&
          bytes[3] == 0x53) {
        return 'ogg';
      }
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x41 &&
          bytes[10] == 0x56 &&
          bytes[11] == 0x45) {
        return 'wav';
      }
      if (bytes.length >= 3 &&
          bytes[0] == 0x49 &&
          bytes[1] == 0x44 &&
          bytes[2] == 0x33) {
        return 'mp3';
      }
      if (bytes.length >= 2 && bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0) {
        return 'mp3';
      }
      if (bytes.length >= 8 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        return 'm4a';
      }
      return null;
    } finally {
      await handle?.close();
    }
  }

  static String _imageMime(String url) {
    final String lower = url.toLowerCase();
    if (lower.contains('.png')) return 'image/png';
    if (lower.contains('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  static String _extension(String url, String quality, String resolvedFormat) {
    if (resolvedFormat.isNotEmpty) return resolvedFormat.toLowerCase();
    final String? fromUrl = RegExp(
      r'\.(mp3|flac|m4a|aac|wav|ogg|opus)(?:[?#]|$)',
      caseSensitive: false,
    ).firstMatch(url)?.group(1);
    if (fromUrl != null) return fromUrl.toLowerCase();
    if (quality.toLowerCase().contains('flac')) return 'flac';
    return 'mp3';
  }

  static String _safeName(String value) {
    final String cleaned = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'HoH Music track' : cleaned;
  }

  static Future<File> _availableFile(
    Directory directory,
    String stem,
    String extension,
  ) async {
    for (int suffix = 0; suffix < 10000; suffix++) {
      final String name = suffix == 0 ? stem : '$stem ($suffix)';
      final File candidate = File(
        '${directory.path}${Platform.pathSeparator}$name.$extension',
      );
      if (!await candidate.exists()) return candidate;
    }
    throw StateError('同名文件过多，无法生成保存路径');
  }
}
