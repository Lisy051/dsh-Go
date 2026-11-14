// 伙伴小屋 › 渠道: where her light-mode replies come from
// (docs/design/companion.md §7). DeepSeek's own API with the app's key is
// built in; the channels added under 酒馆 › 渠道 are offered here too, so a
// third-party OpenAI-compatible endpoint is configured once for both modes.
// The list and its keys stay in tavern_channels.dart / the tavern settings.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_channels.dart';
import '../../l10n/l10n.dart';
import '../../tavern/tavern_settings.dart';
import '../common/app_sheet.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../tavern/tavern_channels_page.dart' show TavernChannelEditPage;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class CompanionModelPage extends ConsumerWidget {
  const CompanionModelPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const CompanionModelPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final active = ref.watch(companionActiveChannelProvider);
    final channels = ref.watch(tavernSettingsProvider.select((s) => s.channels));
    final picked = ref.read(companionChannelProvider.notifier);
    Widget row({
      required String id,
      required String title,
      required String subtitle,
      required bool checked,
      required VoidCallback onTap,
      VoidCallback? onEdit,
    }) => SettingsTile(
      key: ValueKey('companion-channel-$id'),
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onEdit != null)
            IconButton(
              key: ValueKey('companion-channel-$id-edit'),
              tooltip: l10n.tavernChannelEdit,
              icon: const Icon(AppIcons.edit, size: 20),
              onPressed: onEdit,
            ),
          SelectionTick(checked: checked),
        ],
      ),
      onTap: onTap,
    );
    void add() => unawaited(
      Navigator.of(context).push(
        TavernChannelEditPage.route(
          null,
          onSaved: (channel) => unawaited(picked.set(channel.id)),
          showDeepSeekApi: false,
          note: l10n.companionChannelEditorNote,
        ),
      ),
    );
    return AppPage.list(
      title: l10n.companionMenuChannel,
      children: [
        SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [
            row(
              id: 'deepseek',
              title: l10n.tavernChannelDeepSeek,
              subtitle: l10n.tavernChannelDeepSeekNote,
              checked: active == null,
              onTap: () => unawaited(picked.set(null)),
            ),
            for (final channel in channels)
              row(
                id: channel.id,
                title: channel.name,
                subtitle: '${channel.host} · ${channel.model}',
                checked: active?.id == channel.id,
                onTap: () => unawaited(picked.set(channel.id)),
                onEdit: () => unawaited(
                  Navigator.of(context).push(
                    TavernChannelEditPage.route(
                      channel,
                      onSaved: (_) {},
                      showDeepSeekApi: false,
                      note: l10n.companionChannelEditorNote,
                    ),
                  ),
                ),
              ),
            SettingsTile(
              key: const ValueKey('companion-channel-add'),
              icon: AppIcons.add,
              title: l10n.tavernChannelAdd,
              onTap: add,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
          child: Text(
            l10n.companionChannelNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        ),
      ],
    );
  }
}
