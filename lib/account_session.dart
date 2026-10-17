import 'package:flutter/services.dart';

class AccountSession {
  AccountSession(this.token, this.user);
  final String token;
  final Map<String, dynamic> user;
  bool get isAdmin => user['role'] == 'admin';
  String get name => user['name'] as String;
  static AccountSession? current;
  static Map<String, String> get headers => {
    if (current case final session?) 'Authorization': 'Bearer ${session.token}',
  };
  static const storage = MethodChannel('parkguard/account_session');
}
