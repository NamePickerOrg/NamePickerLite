import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:namepicker/main.dart';
import 'package:namepicker/student.dart';
import 'package:namepicker/student_db.dart';
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
    tempDir = await Directory.systemTemp.createTemp('namepicker_draw_');
    await databaseFactory.setDatabasesPath(tempDir.path);
  });

  tearDown(() async {
    await StudentDatabase.instance.close();
    await tempDir.delete(recursive: true);
  });

  Future<MyAppState> readyState({
    Future<List<Student>> Function(int listId)? readStudents,
  }) async {
    final appState = MyAppState(readStudents: readStudents);
    await appState.refreshLists();
    return appState;
  }

  Future<Student> addStudent(
    int listId,
    String name,
    String studentId, {
    String gender = '男',
  }) {
    return StudentDatabase.instance.create(
      Student(name: name, gender: gender, studentId: studentId),
      listId,
    );
  }

  test('允许重复时同一批可以重复命中同一学生', () async {
    final appState = await readyState();
    final listId = appState.currentListId!;
    await addStudent(listId, '张三', '001');
    appState.setAllowRepeat(true);

    await appState.drawStudents(3);

    expect(appState.drawStatus, DrawStatus.ready);
    expect(appState.latestDraw, hasLength(3));
    expect(appState.latestDraw.every((s) => s.name == '张三'), isTrue);
    expect(appState.history, hasLength(3));
    expect(appState.pickedIds, isEmpty);
  });

  test('关闭重复时同批跨轮，且已抽集合只保留新轮记录', () async {
    final appState = await readyState();
    final listId = appState.currentListId!;
    await addStudent(listId, '张三', '1');
    await addStudent(listId, '李四', '2');
    appState.setAllowRepeat(false);

    await appState.drawStudents(3);

    expect(appState.drawStatus, DrawStatus.ready);
    final ids = appState.latestDraw.map((s) => s.id).toList();
    expect(ids, hasLength(3));
    expect(ids[0], isNot(ids[1]));
    expect(ids[2], anyOf(ids[0], ids[1]));
    expect(appState.pickedIds, hasLength(1));
    expect(appState.pickedIds.single, ids[2]);
  });

  test('未抽过的候选会跨批次保留', () async {
    final appState = await readyState();
    final listId = appState.currentListId!;
    await addStudent(listId, '张三', '1');
    await addStudent(listId, '李四', '2');
    appState.setAllowRepeat(false);

    await appState.drawStudents(1);
    final first = appState.latestDraw.single.id;
    await appState.drawStudents(1);

    expect(appState.latestDraw.single.id, isNot(first));
    expect(appState.pickedIds, hasLength(2));
  });

  test('筛选无匹配不增加历史，也不重置已抽集合', () async {
    final appState = await readyState();
    final listId = appState.currentListId!;
    await addStudent(listId, '张三', '1');
    await addStudent(listId, '李四', '2');
    appState.setAllowRepeat(false);

    await appState.drawStudents(1);
    final pickedBefore = Set<int>.from(appState.pickedIds);
    expect(appState.history, hasLength(1));

    appState.setFilterGender('女');
    await appState.drawStudents(1);
    expect(appState.drawStatus, DrawStatus.noCandidates);
    expect(appState.history, hasLength(1));
    expect(appState.pickedIds, pickedBefore);

    appState.setFilterGender('男');
    await appState.drawStudents(1);
    expect(appState.drawStatus, DrawStatus.ready);
    expect(appState.latestDraw.single.id, isNot(pickedBefore.single));
    expect(appState.history, hasLength(2));
  });

  test('重置或切换名单后，在途查询的结果被丢弃', () async {
    final completer = Completer<List<Student>>();
    var reads = 0;
    late MyAppState appState;
    appState = MyAppState(
      readStudents: (listId) {
        reads++;
        if (reads == 1) return completer.future;
        return StudentDatabase.instance.readAll(listId);
      },
    );
    await appState.refreshLists();
    final listId = appState.currentListId!;
    await addStudent(listId, '张三', '1');

    final pending = appState.drawStudents(1);
    // 让抽选走到读库这一步。
    await Future<void>.delayed(Duration.zero);
    appState.reset();
    completer.complete(await StudentDatabase.instance.readAll(listId));
    await pending;

    expect(appState.history, isEmpty);
    expect(appState.pickedIds, isEmpty);
    expect(appState.drawStatus, DrawStatus.idle);
    expect(appState.isDrawing, isFalse);
  });

  test('A→B→A 切换后，旧名单的在途查询不提交结果', () async {
    final completer = Completer<List<Student>>();
    var reads = 0;
    final appState = MyAppState(
      readStudents: (listId) {
        reads++;
        if (reads == 1) return completer.future;
        return StudentDatabase.instance.readAll(listId);
      },
    );
    await appState.refreshLists();
    final firstId = appState.currentListId!;
    await addStudent(firstId, '张三', '1');
    final secondId = await appState.createList('第二名单');
    await addStudent(secondId, '李四', '2');
    appState.setCurrentListId(firstId);

    final pending = appState.drawStudents(1);
    await Future<void>.delayed(Duration.zero);
    appState.setCurrentListId(secondId);
    appState.setCurrentListId(firstId);
    completer.complete(await StudentDatabase.instance.readAll(firstId));
    await pending;

    expect(appState.history, isEmpty);
    expect(appState.drawStatus, DrawStatus.idle);
    expect(appState.isDrawing, isFalse);
  });

  test('抽选进行中重复触发只执行首个批次', () async {
    final completer = Completer<List<Student>>();
    var reads = 0;
    final appState = MyAppState(
      readStudents: (listId) {
        reads++;
        return completer.future;
      },
    );
    await appState.refreshLists();
    final listId = appState.currentListId!;
    final student = await addStudent(listId, '张三', '1');

    final first = appState.drawStudents(1);
    final second = appState.drawStudents(1);
    await Future<void>.delayed(Duration.zero);
    expect(appState.isDrawing, isTrue);
    completer.complete([student]);
    await Future.wait([first, second]);

    expect(reads, 1);
    expect(appState.latestDraw, hasLength(1));
    expect(appState.isDrawing, isFalse);
  });

  test('初始化完成前请求抽选，使用已加载的设置而不是默认值', () async {
    SharedPreferences.setMockInitialValues({
      'filterGender': '女',
      'allowRepeat': false,
    });
    final appState = MyAppState();
    expect(appState.isReady, isFalse);

    final listId = (await StudentDatabase.instance.readAllLists()).first.id!;
    await addStudent(listId, '张三', '1');
    await addStudent(listId, '李四', '2', gender: '女');

    await appState.drawStudents(1);

    expect(appState.isReady, isTrue);
    expect(appState.filterGender, '女');
    expect(appState.allowRepeat, isFalse);
    expect(appState.latestDraw.single.name, '李四');
    expect(appState.pickedIds, hasLength(1));
  });

  test('未知名单 ID 不会改变当前选择', () async {
    final appState = await readyState();
    final current = appState.currentListId;
    appState.setCurrentListId(999999);
    expect(appState.currentListId, current);
    appState.setCurrentListId(-1);
    expect(appState.currentListId, current);
    appState.setCurrentListId(null);
    expect(appState.currentListId, current);
  });

  test('删除名单依赖数据库影响行数，最后一个名单被保护', () async {
    final appState = await readyState();
    final onlyId = appState.currentListId!;
    expect(await appState.deleteList(onlyId), isFalse);
    expect(appState.lists.map((l) => l.id), contains(onlyId));

    final extraId = await appState.createList('额外');
    expect(await appState.deleteList(extraId), isTrue);
    expect(appState.lists.map((l) => l.id), isNot(contains(extraId)));
  });

  test('名单内容变更会使当前名单的抽选会话失效并递增版本号', () async {
    final appState = await readyState();
    final listId = appState.currentListId!;
    await addStudent(listId, '张三', '1');
    await appState.drawStudents(1);
    expect(appState.history, hasLength(1));

    final revisionBefore = appState.rosterRevision;
    appState.studentsChanged(listId);

    expect(appState.rosterRevision, revisionBefore + 1);
    expect(appState.history, isEmpty);
    expect(appState.latestDraw, isEmpty);
    expect(appState.pickedIds, isEmpty);
  });

  test('读库失败进入错误状态并释放忙碌标记', () async {
    final appState = await readyState(
      readStudents: (listId) async => throw StateError('boom'),
    );
    await addStudent(appState.currentListId!, '张三', '1');

    await appState.drawStudents(1);

    expect(appState.drawStatus, DrawStatus.error);
    expect(appState.latestDraw, isEmpty);
    expect(appState.isDrawing, isFalse);
  });

  test('批次人数必须大于零', () async {
    final appState = await readyState();
    await expectLater(appState.drawStudents(0), throwsArgumentError);
    await expectLater(appState.drawStudents(-1), throwsArgumentError);
    expect(appState.isDrawing, isFalse);
  });

  test('人数与候选人数无关，不做截断', () async {
    final appState = MyAppState(random: Random(7));
    await appState.refreshLists();
    final listId = appState.currentListId!;
    await addStudent(listId, '张三', '1');

    await appState.drawStudents(50);

    expect(appState.latestDraw, hasLength(50));
    expect(appState.history, hasLength(50));
  });
}
