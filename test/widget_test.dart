// Basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echoread/core/widgets/cover_image.dart';

void main() {
  testWidgets('CoverImage renders the placeholder without a URL',
      (WidgetTester tester) async {
    // A cover with no URL or local file must never touch the network — it
    // falls back to the generic book placeholder. MaterialApp provides the
    // Directionality ancestor that Icon requires.
    await tester.pumpWidget(MaterialApp(home: const CoverImage()));

    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
  });
}
