import 'dart:convert';

import 'package:http/http.dart' as http;

import 'account_session.dart';

class AccountApi {
  AccountApi({
    http.Client? client,
    this.baseUrl = const String.fromEnvironment('API_BASE_URL'),
  }) : _client = client ?? http.Client();
  final String baseUrl;
  final http.Client _client;
  Future<dynamic> request(
    String path, {
    Map<String, dynamic>? body,
    bool post = false,
  }) async {
    if (baseUrl.isEmpty) throw StateError('Account server is not configured');
    final uri = Uri.parse('$baseUrl/api/v1$path');
    final headers = {
      ...AccountSession.headers,
      'Content-Type': 'application/json',
    };
    final response =
        await (post
                ? _client.post(
                    uri,
                    headers: headers,
                    body: jsonEncode(body ?? {}),
                  )
                : _client.get(uri, headers: headers))
            .timeout(const Duration(seconds: 25));
    final decoded = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      if (response.statusCode == 401 && AccountSession.current != null) {
        throw AccountExpired();
      }
      final detail = decoded is Map ? decoded['detail'] : null;
      throw StateError(
        detail is String
            ? detail
            : 'Check the form and try again (${response.statusCode})',
      );
    }
    return decoded;
  }

  void close() => _client.close();
}

class AccountExpired implements Exception {
  @override
  String toString() => 'Session expired. Sign out and sign in again.';
}
