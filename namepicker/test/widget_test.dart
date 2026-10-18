import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namepicker/main.dart';
import 'package:namepicker/student.dart';
import 'package:namepicker/student_db.dart';
import 'package:namepicker/student_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StudentDatabase.instance.close();
    tempDir = await Directory.systemTemp.createTemp('namepicker_test_');
    await databaseFactory.setDatabasesPath(tempDir.path);
  });

  tearDown(() async {
    await StudentDatabase.instance.close();
    await tempDir.delete(recursive: true);
  });

  test('删除当前名单会删除其学生并同步切换选择', () async {
    final appState = MyAppState();
    await appState.refreshLists();

    final keepId = appState.currentListId!;
    final deleteId = await appState.createList('待删除');
    await StudentDatabase.instance.create(
      Student(name: '张三', gender: '男', studentId: '1'),
      deleteId,
    );

    expect(appState.currentListId, deleteId);
    expect(await StudentDatabase.instance.readAll(deleteId), hasLength(1));

    expect(await appState.deleteList(deleteId), isTrue);

    expect(appState.lists.map((l) => l.id), isNot(contains(deleteId)));
    expect(appState.currentListId, keepId);
    expect(await StudentDatabase.instance.readAll(deleteId), isEmpty);

    await appState.drawStudents(1);
    expect(appState.drawStatus, DrawStatus.noCandidates);
    expect(appState.latestDraw, isEmpty);
  });

  test('最后一个名单不能被删除', () async {
    final appState = MyAppState();
    await appState.refreshLists();

    final onlyId = appState.currentListId!;
    expect(await appState.deleteList(onlyId), isFalse);
    expect(appState.lists.map((l) => l.id), contains(onlyId));
    expect(appState.currentListId, onlyId);
  });

  testWidgets('编辑页随全局名单切换刷新学生', (tester) async {
    late MyAppState appState;
    late int firstId;
    late int secondId;

    // testWidgets 默认在 fake async 中运行，sqflite 的真实 IO 必须放在
    // runAsync 内才会完成。
    await tester.runAsync(() async {
      appState = MyAppState();
      await appState.refreshLists();
      firstId = appState.currentListId!;
      await StudentDatabase.instance.create(
        Student(name: '李四', gender: '男', studentId: '2'),
        firstId,
      );
    });

    // 有界地推进帧，避免被 CircularProgressIndicator 的无限动画卡住。
    Future<void> waitForListLoad() async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          return;
        }
      }
      fail('名单加载超时');
    }

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: appState,
        child: MaterialApp(home: StudentEditorPage()),
      ),
    );
    await waitForListLoad();
    expect(find.text('李四'), findsOneWidget);

    await tester.runAsync(() async {
      secondId = await appState.createList('第二名单');
      await StudentDatabase.instance.create(
        Student(name: '王五', gender: '女', studentId: '3'),
        secondId,
      );
    });
    await waitForListLoad();
    expect(find.text('李四'), findsNothing);

    await tester.runAsync(() async {
      appState.setCurrentListId(firstId);
    });
    await waitForListLoad();
    expect(find.text('李四'), findsOneWidget);
    expect(find.text('王五'), findsNothing);
  });

  test('旧版本遗留的孤儿学生会在重新打开数据库时清理', () async {
    final appState = MyAppState();
    await appState.refreshLists();

    final db = await StudentDatabase.instance.database;
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.insert('students', {
      'name': '孤儿',
      'gender': '男',
      'studentId': '99',
      'listId': 99999,
    });
    await db.execute('PRAGMA foreign_keys = ON');
    expect(await StudentDatabase.instance.readAll(99999), hasLength(1));

    await StudentDatabase.instance.close();
    expect(await StudentDatabase.instance.readAll(99999), isEmpty);
  });

  testWidgets('编辑页只接受最新一次加载结果', (tester) async {
    final completers = <int, Completer<List<Student>>>{};
    var calls = 0;
    final appState = MyAppState(readStudents: (listId) {
      calls++;
      final completer = Completer<List<Student>>();
      completers[calls] = completer;
      return completer.future;
    });
    late int listA;
    late int listB;
    await tester.runAsync(() async {
      await appState.refreshLists();
      listA = appState.currentListId!;
      listB = await appState.createList('第二名单');
      appState.setCurrentListId(listA);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: appState,
        child: MaterialApp(home: StudentEditorPage()),
      ),
    );
    await tester.pump();
    expect(calls, 1);

    await tester.runAsync(() async {
      appState.setCurrentListId(listB);
    });
    await tester.pump();
    expect(calls, 2);

    await tester.runAsync(() async {
      appState.setCurrentListId(listA);
    });
    await tester.pump();
    expect(calls, 3);

    // 最新一次请求先完成。
    completers[3]!.complete([
      Student(id: 1, name: '最新', gender: '男', studentId: '3'),
    ]);
    await tester.pump();
    expect(find.text('最新'), findsOneWidget);

    // 早先的请求后完成，不能覆盖最新数据。
    completers[1]!.complete([
      Student(id: 2, name: '最旧', gender: '男', studentId: '1'),
    ]);
    completers[2]!.complete([
      Student(id: 3, name: '中间', gender: '男', studentId: '2'),
    ]);
    await tester.pump();
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('最旧'), findsNothing);
    expect(find.text('中间'), findsNothing);
  });

  testWidgets('编辑页加载失败可重试，加载完成前不可导出', (tester) async {
    var failNext = true;
    final appState = MyAppState(readStudents: (listId) async {
      if (failNext) throw StateError('boom');
      return [Student(id: 1, name: '张三', gender: '男', studentId: '1')];
    });
    await tester.runAsync(() => appState.refreshLists());

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: appState,
        child: MaterialApp(home: StudentEditorPage()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('名单加载失败'), findsOneWidget);

    await tester.tap(find.byTooltip('操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出名单'));
    await tester.pumpAndSettle();
    // 加载未完成时导出被守卫拦下：既不提示成功，也不走到平台文件接口。
    expect(find.text('导出完成'), findsNothing);
    expect(find.text('导出失败，请重试'), findsNothing);

    failNext = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(find.text('张三'), findsOneWidget);
  });
}
