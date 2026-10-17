import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parking_violation_app/account_api.dart';
import 'package:parking_violation_app/account_portal.dart';
import 'package:parking_violation_app/account_session.dart';

void main() {
  tearDown(() => AccountSession.current = null);
  testWidgets('signup submits name and vehicle, never an admin role', (
    tester,
  ) async {
    Map<String, dynamic>? sent;
    final api = AccountApi(
      baseUrl: 'https://test',
      client: MockClient((request) async {
        sent = jsonDecode(request.body);
        return http.Response(
          jsonEncode({
            'token': 'test',
            'user': {'name': 'Alice', 'role': 'user'},
          }),
          201,
        );
      }),
    );
    addTearDown(api.close);
    var signedIn = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AccountForm(
          api: api,
          onSignedIn: (_) async {
            signedIn = true;
          },
        ),
      ),
    );
    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Alice');
    await tester.enterText(fields.at(1), 'KA01AB1234');
    await tester.enterText(fields.at(2), 'alice@example.com');
    await tester.enterText(fields.at(3), 'Password123!');
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(signedIn, isTrue);
    expect(sent, {
      'name': 'Alice',
      'plate': 'KA01AB1234',
      'email': 'alice@example.com',
      'password': 'Password123!',
    });
  });
  test(
    'account requests carry the current bearer token and surface failures',
    () async {
      AccountSession.current = AccountSession('private-token', {
        'name': 'Alice',
        'role': 'user',
      });
      final api = AccountApi(
        baseUrl: 'https://test',
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer private-token');
          return http.Response('{"detail":"Penalty not found"}', 404);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.request('/penalties/other/demo-pay', post: true),
        throwsStateError,
      );
    },
  );
}
