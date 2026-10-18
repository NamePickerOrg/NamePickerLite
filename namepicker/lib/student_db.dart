import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'student.dart';

class ListGroup {
  int? id;
  String name;
  ListGroup({this.id, required this.name});
  Map<String, dynamic> toMap() => {'id': id, 'name': name};
  factory ListGroup.fromMap(Map<String, dynamic> map) =>
      ListGroup(id: map['id'], name: map['name']);
}

class StudentDatabase {
  static final StudentDatabase instance = StudentDatabase._init();
  static Database? _database;

  StudentDatabase._init();

  /// 进行中的打开操作。并发调用共享同一个 Future，失败后释放以便重试。
  static Future<Database>? _opening;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;
    final opening = _opening;
    if (opening != null) return opening;
    final future = _initDB('students.db');
    _opening = future;
    try {
      final db = await future;
      _database = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        // SQLite 默认不启用外键，不开启则 ON DELETE CASCADE 不会生效。
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onOpen: (db) async {
        // 清理旧版本删除名单后遗留的孤儿学生，避免已删除名单仍可抽选。
        await db.delete(
          'students',
          where: 'listId NOT IN (SELECT id FROM lists)',
        );
      },
      onCreate: _createDB,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE lists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE students (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        gender TEXT NOT NULL,
        studentId TEXT NOT NULL,
        listId INTEGER NOT NULL,
        FOREIGN KEY(listId) REFERENCES lists(id) ON DELETE CASCADE
      )
    ''');
  }

  Future<Student> create(Student student, int listId) async {
    final db = await instance.database;
    final id = await db.insert('students', {
      'name': student.name,
      'gender': student.gender,
      'studentId': student.studentId,
      'listId': listId,
    });
    return student..id = id..listId = listId;
  }

  /// 一次事务写入多条学生记录；任一失败整体回滚。
  Future<int> createMany(List<Student> students, int listId) async {
    if (students.isEmpty) return 0;
    final db = await instance.database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final student in students) {
        batch.insert('students', {
          'name': student.name,
          'gender': student.gender,
          'studentId': student.studentId,
          'listId': listId,
        });
      }
      await batch.commit(noResult: true);
    });
    return students.length;
  }

  Future<List<Student>> readAll(int listId) async {
    final db = await instance.database;
    final result = await db.query(
      'students',
      where: 'listId = ?',
      whereArgs: [listId],
      orderBy: 'id ASC',
    );
    return result.map((map) => Student.fromMap(map)).toList();
  }

  /// 只更新学生自身字段，不改动 id 与所属名单。
  Future<int> update(Student student) async {
    final db = await instance.database;
    return db.update(
      'students',
      {
        'name': student.name,
        'gender': student.gender,
        'studentId': student.studentId,
      },
      where: 'id = ?',
      whereArgs: [student.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await instance.database;
    return db.delete('students', where: 'id = ?', whereArgs: [id]);
  }

  // 名单相关
  Future<int> createList(String name) async {
    final db = await instance.database;
    return await db.insert('lists', {'name': name});
  }

  Future<List<ListGroup>> readAllLists() async {
    final db = await instance.database;
    final result = await db.transaction((txn) async {
      var rows = await txn.query('lists', orderBy: 'id ASC');
      if (rows.isEmpty) {
        // 自动创建一个默认名单。放入事务，避免并发读到空名单。
        await txn.insert('lists', {'name': '默认名单'});
        rows = await txn.query('lists', orderBy: 'id ASC');
      }
      return rows;
    });
    return result.map((map) => ListGroup.fromMap(map)).toList();
  }

  Future<int> updateList(ListGroup list) async {
    final db = await instance.database;
    return db.update(
      'lists',
      list.toMap(),
      where: 'id = ?',
      whereArgs: [list.id],
    );
  }

  /// 删除名单及其学生。目标不存在或只剩一个名单时返回 0，成功返回 1。
  Future<int> deleteList(int id) async {
    final db = await instance.database;
    // 显式删除学生，不依赖调用方是否启用了外键约束。
    return db.transaction((txn) async {
      final target = await txn.query(
        'lists',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [id],
      );
      if (target.isEmpty) return 0;
      final count = Sqflite.firstIntValue(
        await txn.rawQuery('SELECT COUNT(*) FROM lists'),
      );
      if (count == null || count <= 1) return 0;
      await txn.delete('students', where: 'listId = ?', whereArgs: [id]);
      return txn.delete('lists', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future close() async {
    // 若打开仍在进行，先等它结束，避免关闭后又被写回缓存。
    final opening = _opening;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {
        // 打开失败时没有连接需要关闭。
      }
    }
    final db = _database;
    _database = null;
    if (db != null) {
      await db.close();
    }
  }
}
