import 'package:flutter_test/flutter_test.dart';
import 'package:namepicker/qr_transfer.dart';

void main() {
  group('负载编解码', () {
    test('单包压缩往返保持原文', () {
      const csv = 'name,sex,no\r\n张三,0,001\r\n';
      final payload = encodeQrPayload(csv);
      expect(payload.startsWith('Z:'), isTrue);
      expect(decodeQrPayload(payload), csv);
    });

    test('兼容旧版明文 CSV', () {
      const csv = 'name,sex,no\r\n李四,1,002';
      expect(decodeQrPayload(csv), csv);
    });

    test('长度前缀与内容不符时拒绝', () {
      expect(
        () => decodeQrPayload('Z:0001:AAAA'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('分片', () {
    test('长负载切分后按序拼接可还原', () {
      final payload = List.filled(qrChunkSize * 3 + 17, 'a').join();
      final chunks = splitQrPayload(payload);
      expect(chunks, hasLength(4));

      final rebuilt = StringBuffer();
      for (var i = 0; i < chunks.length; i++) {
        final ref = parseQrChunk(chunks[i])!;
        expect(ref.index, i + 1);
        expect(ref.total, 4);
        rebuilt.write(ref.payload);
      }
      expect(rebuilt.toString(), payload);
    });

    test('短负载不切分', () {
      expect(splitQrPayload('abc'), ['abc']);
    });

    test('分片数超过上限时拒绝生成', () {
      final oversized = List.filled(qrChunkSize * 1025 + 1, 'a').join();
      expect(
        () => splitQrPayload(oversized),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('名单过大'),
          ),
        ),
      );
    });

    test('没有分片后缀返回 null', () {
      expect(parseQrChunk('Z:0001:AAAA'), isNull);
    });

    test('非法分片在后缀解析阶段拒绝', () {
      for (final raw in [
        'abc|0/3',
        'abc|4/3',
        'abc|1/0',
        'abc|1/999999',
        'abc|1/1025',
        '|1/3',
      ]) {
        expect(
          () => parseQrChunk(raw),
          throwsA(isA<FormatException>()),
          reason: raw,
        );
      }
    });

    test('合法分片包含内容、序号与总数', () {
      final ref = parseQrChunk('hello|2/3')!;
      expect(ref.payload, 'hello');
      expect(ref.index, 2);
      expect(ref.total, 3);
    });
  });
}
