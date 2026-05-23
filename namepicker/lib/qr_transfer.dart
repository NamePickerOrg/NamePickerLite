import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

const _chunkSize = 800;

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

List<String> _splitIntoChunks(String payload) {
  if (payload.length <= _chunkSize) return [payload];
  final chunks = <String>[];
  final total = (payload.length / _chunkSize).ceil();
  for (var i = 0; i < total; i++) {
    final start = i * _chunkSize;
    final end = (start + _chunkSize).clamp(0, payload.length);
    chunks.add('${payload.substring(start, end)}|${i + 1}/$total');
  }
  return chunks;
}

Future<void> showQrExportDialog(BuildContext context, String csvData) {
  final String payload;
  try {
    payload = encodeQrPayload(csvData);
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

  final chunks = _splitIntoChunks(payload);
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

Future<String?> showQrScanner(BuildContext context, {String? title}) {
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
