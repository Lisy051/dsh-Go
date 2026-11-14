// Her brain in light mode (docs/design/companion.md §7): DeepSeek's own API
// with the app's key, or a channel added under 酒馆 › 渠道
// (tavern_channels.dart) so an OpenAI-compatible endpoint can answer her too.
// The list is the tavern's, so a third-party endpoint is configured once and
// both modes see it; each channel's key stays in the tavern key store, never
// in preferences.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tavern/tavern_channels.dart';
import '../tavern/tavern_settings.dart';
import 'companion_light.dart';

/// The id of the channel light mode uses; null is DeepSeek's own.
class CompanionChannelSetting extends Notifier<String?> {
  static const key = 'companion.channel';

  @override
  String? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(key);
      if (saved != null && saved.isNotEmpty && ref.mounted && state == null) state = saved;
    } catch (_) {
      // No preferences backend (tests): DeepSeek's own.
    }
  }

  Future<void> set(String? id) async {
    state = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      id == null ? await prefs.remove(key) : await prefs.setString(key, id);
    } catch (_) {}
  }
}

final companionChannelProvider = NotifierProvider<CompanionChannelSetting, String?>(CompanionChannelSetting.new);

/// The channel in use, out of the tavern's list; null means DeepSeek's own. A
/// stored id whose channel was deleted in 酒馆 falls back to DeepSeek's own.
final companionActiveChannelProvider = Provider<TavernChannel?>((ref) {
  final id = ref.watch(companionChannelProvider);
  if (id == null) return null;
  for (final channel in ref.watch(tavernSettingsProvider).channels) {
    if (channel.id == id) return channel;
  }
  return null;
});

/// [channel] as the request layer takes it; null for DeepSeek's own route.
CompanionLightChannel? companionLightChannelOf(TavernChannel? channel) => channel == null
    ? null
    : CompanionLightChannel(baseUrl: channel.baseUrl, model: channel.model, headers: channel.headers);
