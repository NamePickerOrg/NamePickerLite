import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:namepicker/csv_transfer.dart';
import 'package:namepicker/student.dart';
import 'package:namepicker/student_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await StudentDatabase.instance.close();
    tempDir = await Directory.systemTemp.createTemp('namepicker_csv_');
    await databaseFactory.setDatabasesPath(tempDir.path);
  });

  tearDown(() async {
    await StudentDatabase.instance.close();
    await tempDir.delete(recursive: true);
  });

  test('往返保留引号、逗号、内部换行与前导零', () {
    final original = [
      Student(name: '张,三', gender: '男', studentId: '001'),
      Student(name: '李"四', gender: '女', studentId: 'A,B'),
      Student(name: '王\n五', gender: '男', studentId: 'A002'),
    ];

    final csv = studentsToCsv(original);
    final parsed = studentsFromCsv(csv);

    expect(parsed, hasLength(original.length));
    for (var i = 0; i < original.length; i++) {
      expect(parsed[i].name, original[i].name);
      expect(parsed[i].gender, original[i].gender);
      expect(parsed[i].studentId, original[i].studentId);
    }
    // 导出使用 CRLF 记录分隔，且不带 BOM。
    expect(csv.contains('\r\n'), isTrue);
    expect(csv.startsWith('\uFEFF'), isFalse);
  });

  test('导出的性别编码为 0/1', () {
    final csv = studentsToCsv([
      Student(name: '张三', gender: '男', studentId: '1'),
      Student(name: '李四', gender: '女', studentId: '2'),
    ]);
    expect(csv, contains('张三,0,1'));
    expect(csv, contains('李四,1,2'));
  });

  test('LF、CRLF 与 BOM 的旧文件都能读取', () {
    final lf = studentsFromCsv('name,sex,no\n张三,0,001\n');
    expect(lf, hasLength(1));
    expect(lf.single.studentId, '001');

    final crlf = studentsFromCsv('\uFEFFname,sex,no\r\n李四,1,002\r\n');
    expect(crlf, hasLength(1));
    expect(crlf.single.gender, '女');
  });

  test('表头顺序或字段名不符时整体拒绝', () {
    expect(
      () => studentsFromCsv('no,sex,name\n001,0,张三\n'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => studentsFromCsv('surname,sex,number\n张三,0,001\n'),
      throwsA(isA<FormatException>()),
    );
  });

  test('非法性别、多余列与空字段被拒绝并指明记录', () {
    expect(
      () => studentsFromCsv('name,sex,no\n张三,2,001\n'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('第 2 条记录'),
        ),
      ),
    );
    expect(
      () => studentsFromCsv('name,sex,no\n张三,0,001,额外\n'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => studentsFromCsv('name,sex,no\n张三,0,001\n李四,1,\n'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('第 3 条记录'),
        ),
      ),
    );
    expect(
      () => studentsFromCsv('name,sex,no'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => studentsFromCsv('name,sex,no\n'),
      throwsA(isA<FormatException>()),
    );
  });

  test('批量写入失败时整体回滚，随后可正常提交', () async {
    final appState = await _ReadyDb.open();
    final listId = appState.$1;
    expect(appState.$2, isNotEmpty);

    final db = await StudentDatabase.instance.database;
    await db.execute('''
      CREATE TRIGGER reject_student BEFORE INSERT ON students
      WHEN NEW.name = '__reject__'
      BEGIN
        SELECT RAISE(ABORT, 'forced failure');
      END;
    ''');

    await StudentDatabase.instance.create(
      Student(name: '原本', gender: '男', studentId: '0'),
      listId,
    );
    final before = await StudentDatabase.instance.readAll(listId);

    await expectLater(
      StudentDatabase.instance.createMany([
        Student(name: '新增一', gender: '男', studentId: '1'),
        Student(name: '__reject__', gender: '男', studentId: '2'),
      ], listId),
      throwsA(isA<DatabaseException>()),
    );

    final afterFailure = await StudentDatabase.instance.readAll(listId);
    expect(afterFailure, hasLength(before.length));
    expect(afterFailure.map((s) => s.name), ['原本']);

    expect(
      await StudentDatabase.instance.createMany([
        Student(name: '新增一', gender: '男', studentId: '1'),
      ], listId),
      1,
    );
    expect(await StudentDatabase.instance.readAll(listId), hasLength(2));
  });

  test('导入追加到捕获的目标名单，目标删除后不会改写到其他名单', () async {
    final (listA, lists) = await _ReadyDb.open();
    expect(lists.length, 1);
    final listB = await StudentDatabase.instance.createList('B');
    await StudentDatabase.instance.create(
      Student(name: '已存在', gender: '男', studentId: '9'),
      listA,
    );

    await StudentDatabase.instance.createMany(
      studentsFromCsv('name,sex,no\n张三,0,1\n李四,1,2\n'),
      listA,
    );
    expect(await StudentDatabase.instance.readAll(listA), hasLength(3));
    expect(await StudentDatabase.instance.readAll(listB), isEmpty);

    // 重复导入继续追加，不去重、不覆盖。
    await StudentDatabase.instance.createMany(
      studentsFromCsv('name,sex,no\n张三,0,1\n'),
      listA,
    );
    expect(await StudentDatabase.instance.readAll(listA), hasLength(4));

    expect(await StudentDatabase.instance.deleteList(listA), 1);
    await expectLater(
      StudentDatabase.instance.createMany(
        studentsFromCsv('name,sex,no\n王五,0,3\n'),
        listA,
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(await StudentDatabase.instance.readAll(listB), isEmpty);
  });
}

class _ReadyDb {
  /// 打开临时数据库并返回（默认名单 ID，全部名单）。
  static Future<(int, List<ListGroup>)> open() async {
    final lists = await StudentDatabase.instance.readAllLists();
    return (lists.first.id!, lists);
  }
}
