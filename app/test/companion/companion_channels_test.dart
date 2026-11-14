// 伙伴小屋 › 渠道: the page lists DeepSeek's own endpoint and the channels
// added in 酒馆, and picking one is the choice light mode sends with. The list
// is the tavern's (tavern_settings.dart); no engine runs here.

import 'package:dsh_app/companion/companion_channels.dart';
import 'package:dsh_app/tavern/tavern_channels.dart';
import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/companion/companion_model_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

class _Keys implements TavernChannelKeys {
  final stored = <String, String>{};
  final headers = <String, Map<String, String>>{};

  @override
  Future<String?> read(String id) async => stored[id];

  @override
  Future<void> write(String id, String key) async => stored[id] = key;

  @override
  Future<Map<String, String>> readHeaders(String id) async => headers[id] ?? const {};

  @override
  Future<void> writeHeaders(String id, Map<String, String> value) async =>
      value.isEmpty ? headers.remove(id) : headers[id] = value;

  @override
  Future<void> delete(String id) async {
    stored.remove(id);
    headers.remove(id);
  }
}

const _relay = TavernChannel(id: 'c1', name: 'Relay', baseUrl: 'https://relay.example/v1', model: 'gpt-x');

Widget _app(_Keys keys) => ProviderScope(
  overrides: [tavernChannelKeysProvider.overrideWithValue(keys)],
  child: MaterialApp(
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const CompanionModelPage(),
  ),
);

void main() {
  testWidgets('lists DeepSeek and the tavern channels; a pick is kept and clears', (tester) async {
    SharedPreferences.setMockInitialValues({'tavern.channels': TavernChannel.listToJson([_relay])});
    await tester.pumpWidget(_app(_Keys()));
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek 官方'), findsOneWidget);
    expect(find.text('Relay'), findsOneWidget);
    expect(find.text('relay.example · gpt-x'), findsOneWidget);

    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    expect(container.read(companionActiveChannelProvider), isNull);

    await tester.tap(find.byKey(const ValueKey('companion-channel-c1')));
    await tester.pumpAndSettle();
    expect(container.read(companionChannelProvider), 'c1');
    expect(container.read(companionActiveChannelProvider)?.name, 'Relay');

    await tester.tap(find.byKey(const ValueKey('companion-channel-deepseek')));
    await tester.pumpAndSettle();
    expect(container.read(companionChannelProvider), isNull);
    expect(container.read(companionActiveChannelProvider), isNull);
  });

  testWidgets('a channel deleted in 酒馆 falls back to DeepSeek', (tester) async {
    SharedPreferences.setMockInitialValues({
      'tavern.channels': TavernChannel.listToJson([_relay]),
      'companion.channel': 'c1',
    });
    await tester.pumpWidget(_app(_Keys()));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    expect(container.read(companionActiveChannelProvider)?.id, 'c1');

    // 酒馆 removes it; the stored id is left behind but resolves to nothing.
    await container.read(tavernSettingsProvider.notifier).deleteChannel('c1');
    await tester.pumpAndSettle();
    expect(container.read(companionChannelProvider), 'c1');
    expect(container.read(companionActiveChannelProvider), isNull);
  });
}
