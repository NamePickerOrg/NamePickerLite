import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

class Contributor {
  final String login;
  final String name;
  final String avatarUrl;
  final String profile;
  final List<String> contributions;

  const Contributor({
    required this.login,
    required this.name,
    required this.avatarUrl,
    required this.profile,
    required this.contributions,
  });

  factory Contributor.fromJson(Map<String, dynamic> json) {
    return Contributor(
      login: json['login'] as String,
      name: json['name'] as String,
      avatarUrl: json['avatar_url'] as String,
      profile: json['profile'] as String,
      contributions: List<String>.from(json['contributions'] as List),
    );
  }
}

Future<List<Contributor>> loadContributors() async {
  final jsonStr = await rootBundle.loadString('assets/all_contributors.json');
  final data = json.decode(jsonStr) as Map<String, dynamic>;
  final list = data['contributors'] as List<dynamic>;
  return list.map((c) => Contributor.fromJson(c as Map<String, dynamic>)).toList();
}
