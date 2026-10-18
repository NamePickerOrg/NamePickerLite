import 'package:csv/csv.dart';

import 'student.dart';

/// 名单 CSV 的固定表头与列顺序。
const List<String> csvHeader = ['name', 'sex', 'no'];

/// 导出名单为 RFC 4180 CSV：UTF-8 无 BOM、CRLF 记录分隔、性别 0=男/1=女。
String studentsToCsv(List<Student> students) {
  final rows = <List<String>>[
    csvHeader,
    for (final student in students)
      [
        student.name,
        student.gender == '女' ? '1' : '0',
        student.studentId,
      ],
  ];
  return const ListToCsvConverter(eol: '\r\n').convert(rows);
}

/// 完整解析整份 CSV；任何格式问题都抛 [FormatException]，不返回部分结果。
///
/// 记录分隔符由表头末尾的第一个换行决定（CRLF、LF 或 CR），因此引号内的
/// 换行不会被替换掉。数据记录从表头之后开始，序号含表头、从 1 开始。
List<Student> studentsFromCsv(String text) {
  final withoutBom = text.startsWith('\uFEFF') ? text.substring(1) : text;
  final eol = _firstRecordSeparator(withoutBom);
  if (eol == null) {
    throw const FormatException('没有数据行');
  }

  final List<List<String>> rows;
  try {
    rows = const CsvToListConverter(
      shouldParseNumbers: false,
      allowInvalid: false,
    ).convert<String>(withoutBom, eol: eol);
  } on FormatException {
    throw const FormatException('CSV 格式无效');
  } on ArgumentError {
    throw const FormatException('CSV 格式无效');
  }

  if (rows.isEmpty) {
    throw const FormatException('没有数据行');
  }
  final header = rows.first
      .map((field) => field.trim().toLowerCase())
      .toList(growable: false);
  if (header.length != csvHeader.length) {
    throw const FormatException('表头必须为 name,sex,no');
  }
  for (var i = 0; i < csvHeader.length; i++) {
    if (header[i] != csvHeader[i]) {
      throw const FormatException('表头必须为 name,sex,no');
    }
  }

  final students = <Student>[];
  for (var i = 1; i < rows.length; i++) {
    final recordNumber = i + 1;
    final row = rows[i];
    // 完全空白的记录（例如文件末尾的换行）直接跳过。
    if (row.isEmpty ||
        (row.length == 1 && row.first.trim().isEmpty)) {
      continue;
    }
    if (row.length != 3) {
      throw FormatException(
        '第 $recordNumber 条记录：应为 3 列，实际 ${row.length} 列',
      );
    }
    final name = row[0].trim();
    final sexRaw = row[1].trim();
    final studentNumber = row[2].trim();
    if (name.isEmpty) {
      throw FormatException('第 $recordNumber 条记录：姓名不能为空');
    }
    if (studentNumber.isEmpty) {
      throw FormatException('第 $recordNumber 条记录：学号不能为空');
    }
    if (sexRaw != '0' && sexRaw != '1') {
      throw FormatException('第 $recordNumber 条记录：性别只能为 0（男）或 1（女）');
    }
    students.add(
      Student(
        name: name,
        gender: sexRaw == '1' ? '女' : '男',
        studentId: studentNumber,
      ),
    );
  }

  if (students.isEmpty) {
    throw const FormatException('没有数据行');
  }
  return students;
}

String? _firstRecordSeparator(String text) {
  final lf = text.indexOf('\n');
  final cr = text.indexOf('\r');
  if (cr >= 0 && (lf < 0 || cr < lf)) {
    final isCrLf = cr + 1 < text.length && text[cr + 1] == '\n';
    return isCrLf ? '\r\n' : '\r';
  }
  if (lf >= 0) return '\n';
  return null;
}
