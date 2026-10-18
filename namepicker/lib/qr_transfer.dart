import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

String encodeQrPayload(String csvData) {
  final original = utf8.encode(csvData);
  final compressed = gzip.encode(original);
  final encoded = base64.encode(compressed);
  final lenHex = compressed.length.toRadixString(16).padLeft(4, '0');
  return 'Z:$lenHex:$encoded';
}

String decodeQrPayload(String data) {
  if (!data.startsWith('Z:')) return data;

  final rest = data.substring(2);
  final sep = rest.indexOf(':');
  if (sep < 0) {
    throw FormatException('二维码格式无效：缺少长度前缀');
  }

  final lenHex = rest.substring(0, sep);
  final expectedLen = int.tryParse(lenHex, radix: 16);
  if (expectedLen == null) {
    throw FormatException('二维码格式无效：长度前缀无法解析');
  }

  final encoded = rest.substring(sep + 1);
  if (encoded.isEmpty) {
    throw FormatException('二维码内容为空');
  }

  final compressed = base64.decode(encoded);
  if (compressed.length != expectedLen) {
    throw FormatException(
      '数据完整性校验失败：期望 $expectedLen 字节，实际 ${compressed.length} 字节。'
      '请重新扫描。',
    );
  }

  final decompressed = gzip.decode(compressed);
  return utf8.decode(decompressed);
}

/// 单张二维码的负载上限（字符数）。
const int qrChunkSize = 800;

/// 分片总数上限，避免历史数据的内存分配失控。
const int qrMaxChunks = 1024;

/// 把负载切成 [qrChunkSize] 大小的分片，附加 `|i/total` 后缀。
List<String> splitQrPayload(String payload) {
  if (payload.length <= qrChunkSize) return [payload];
  final total = (payload.length / qrChunkSize).ceil();
  if (total > qrMaxChunks) {
    throw const FormatException('名单过大，请使用 CSV 文件传输');
  }
  final chunks = <String>[];
  for (var i = 0; i < total; i++) {
    final start = i * qrChunkSize;
    final end = (start + qrChunkSize).clamp(0, payload.length);
    chunks.add('${payload.substring(start, end)}|${i + 1}/$total');
  }
  return chunks;
}

/// 已经校验过的分片信息。
class QrChunkRef {
  final String payload;
  final int index;
  final int total;

  const QrChunkRef({
    required this.payload,
    required this.index,
    required this.total,
  });
}

final RegExp _chunkSuffix = RegExp(r'\|(\d+)/(\d+)$');

/// 解析分片二维码；没有分片后缀返回 null，非法分片抛 [FormatException]。
QrChunkRef? parseQrChunk(String raw) {
  final match = _chunkSuffix.firstMatch(raw);
  if (match == null) return null;
  final index = int.tryParse(match.group(1)!);
  final total = int.tryParse(match.group(2)!);
  if (index == null || total == null) {
    throw const FormatException('二维码分片序号无法解析');
  }
  if (total < 1 || total > qrMaxChunks) {
    throw const FormatException('二维码分片总数超出范围');
  }
  if (index < 1 || index > total) {
    throw const FormatException('二维码分片序号超出范围');
  }
  final payload = raw.substring(0, match.start);
  if (payload.isEmpty) {
    throw const FormatException('二维码内容为空');
  }
  return QrChunkRef(payload: payload, index: index, total: total);
}

Future<void> showQrExportDialog(BuildContext context, String csvData) {
  final List<String> chunks;
  try {
    chunks = splitQrPayload(encodeQrPayload(csvData));
  } on FormatException catch (e) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('无法生成二维码'),
        content: Text(e.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('确定'),
          ),
        ],
      ),
    );
  } catch (e) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('无法生成二维码'),
        content: Text('$e'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('确定'),
          ),
        ],
      ),
    );
  }

  if (chunks.length == 1) {
    return _showSingleQrDialog(context, chunks.first, csvData);
  }
  return _showMultiQrDialog(context, chunks, csvData);
}

Future<void> _showSingleQrDialog(
    BuildContext context, String qrData, String csvData) {
  return showDialog(
    context: context,
    builder: (ctx) => Dialog(
      child: Container(
        width: 320,
        padding: EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.qr_code_2, size: 28),
                  SizedBox(width: 8),
                  Text(
                    'QR 码导出',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: EdgeInsets.all(12),
                child: QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: 260,
                  backgroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                ),
              ),
              SizedBox(height: 12),
              Text(
                '请用另一台设备扫描此二维码导入名单',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              SizedBox(height: 8),
              Container(
                width: double.infinity,
                constraints: BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: EdgeInsets.all(8),
                child: SingleChildScrollView(
                  child: Text(
                    csvData,
                    style: TextStyle(fontSize: 10, fontFamily: 'monospace'),
                  ),
                ),
              ),
              SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _showMultiQrDialog(
    BuildContext context, List<String> chunks, String csvData) {
  return showDialog(
    context: context,
    builder: (ctx) => _MultiQrDialog(chunks: chunks, csvData: csvData),
  );
}

class _MultiQrDialog extends StatefulWidget {
  final List<String> chunks;
  final String csvData;

  const _MultiQrDialog({required this.chunks, required this.csvData});

  @override
  State<_MultiQrDialog> createState() => _MultiQrDialogState();
}

class _MultiQrDialogState extends State<_MultiQrDialog> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final total = widget.chunks.length;
    return Dialog(
      child: Container(
        width: 340,
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.qr_code_2, size: 28),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'QR 码导出（第 ${_page + 1}/$total 张）',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: EdgeInsets.all(12),
              child: QrImageView(
                data: widget.chunks[_page],
                version: QrVersions.auto,
                size: 260,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
            ),
            SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: _page > 0 ? () => setState(() => _page--) : null,
                  icon: Icon(Icons.chevron_left),
                  label: Text('上一张'),
                ),
                Text(
                  '${_page + 1} / $total',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                TextButton.icon(
                  onPressed: _page < total - 1
                      ? () => setState(() => _page++)
                      : null,
                  icon: Icon(Icons.chevron_right),
                  label: Text('下一张'),
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(
              '请按顺序扫描全部 $total 张二维码以导入名单',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// mobile_scanner 6.0.11 只声明 Android/iOS/macOS/Web 实现。
bool get qrScannerSupported {
  if (kIsWeb) return true;
  return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
}

Future<String?> showQrScanner(BuildContext context, {String? title}) {
  if (!qrScannerSupported) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('无法扫码'),
        content: const Text('不支持扫码，请使用 CSV 导入'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (ctx) => _QrScannerPage(title: title),
    ),
  );
}

class _QrScannerPage extends StatefulWidget {
  final String? title;
  const _QrScannerPage({this.title});

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  MobileScannerController? _controller;
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.stop();
      await controller.start();
    } catch (_) {
      // 保持可关闭的错误态，用户可以关闭后重新进入。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'QR 码导入'),
        leading: IconButton(
          icon: Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: MobileScanner(
        controller: _controller,
        placeholderBuilder: (context, child) => const Center(
          child: CircularProgressIndicator(),
        ),
        errorBuilder: (context, error, child) {
          final isPermission =
              error.errorCode == MobileScannerErrorCode.permissionDenied;
          final isUnsupported =
              error.errorCode == MobileScannerErrorCode.unsupported;
          final message = isPermission
              ? '相机权限未开启，请在系统设置中允许访问'
              : isUnsupported
                  ? '未检测到可用相机'
                  : '无法启动相机，请重试';
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      if (!isPermission && !isUnsupported)
                        FilledButton(
                          onPressed: _retry,
                          child: const Text('重试'),
                        ),
                      TextButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
        onDetect: (capture) {
          if (_hasScanned) return;
          final barcode = capture.barcodes.firstOrNull;
          if (barcode != null && barcode.rawValue != null) {
            _hasScanned = true;
            Navigator.pop(context, barcode.rawValue);
          }
        },
      ),
    );
  }
}
