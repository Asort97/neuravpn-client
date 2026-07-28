import 'dart:async';

import 'package:flutter/material.dart';

import '../models/vpn_profile.dart';
import '../models/vpn_subscription.dart';
import '../services/subscription_manager.dart';
import '../services/subscription_repository.dart';
import '../vless/vless_parser.dart';
import 'neura_ui.dart';

class ProfileListView extends StatefulWidget {
  const ProfileListView({
    super.key,
    required this.profiles,
    required this.selectedProfile,
    required this.onProfileSelected,
    required this.onDeleteProfile,
    this.subscriptionsRefreshToken = 0,
    this.onSubscriptionsChanged,
  });

  final List<VpnProfile> profiles;
  final VpnProfile? selectedProfile;
  final ValueChanged<VpnProfile> onProfileSelected;
  final ValueChanged<VpnProfile> onDeleteProfile;
  final int subscriptionsRefreshToken;
  final ValueChanged<bool>? onSubscriptionsChanged;

  @override
  State<ProfileListView> createState() => _ProfileListViewState();
}

class _ProfileListViewState extends State<ProfileListView> {
  void _toast(String message, {NeuraToastTone tone = NeuraToastTone.neutral}) {
    showNeuraToast(context, message, tone: tone);
  }

  String _formatVlessSummary(String uri) {
    final parsed = parseVlessUri(uri);
    if (parsed == null) return uri;
    if (parsed.tag != null && parsed.tag!.isNotEmpty) return parsed.tag!;
    if (parsed.sni != null && parsed.sni!.isNotEmpty) return parsed.sni!;
    if (parsed.host.isNotEmpty) return parsed.host;
    return uri;
  }

  String _safeDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  String _vlessDisplayName(String uri) {
    final parsed = parseVlessUri(uri);
    if (parsed == null) return _safeDecode(uri);
    final tag = parsed.tag;
    if (tag != null && tag.trim().isNotEmpty) return _safeDecode(tag.trim());
    final sni = parsed.sni;
    if (sni != null && sni.trim().isNotEmpty) return sni.trim();
    if (parsed.host.trim().isNotEmpty) return parsed.host.trim();
    return _safeDecode(uri);
  }

  String _vlessProtocolLine(String uri) {
    final parsed = parseVlessUri(uri);
    final transport = (parsed?.type?.trim().isNotEmpty ?? false)
        ? parsed!.type!.trim()
        : 'tcp';
    return 'VLESS / ${transport.toUpperCase()}';
  }

  Widget _configTitleMarquee(String text, {required bool enabled}) {
    // Marquee removed: keep UI stable and performant.
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13.5,
        color: Colors.white,
        fontWeight: enabled ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }

  Widget _subscriptionProfileTitle(String uri, {required bool selected}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _configTitleMarquee(_vlessDisplayName(uri), enabled: true),
        const SizedBox(height: 4),
        Text(
          _vlessProtocolLine(uri),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(0.65),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  late final SubscriptionRepository _repository;
  final SubscriptionService _manager = SubscriptionService();
  final NeuraSmoothScrollController _scrollController =
      NeuraSmoothScrollController();
  List<VpnSubscription> _subscriptions = const [];
  final Map<String, bool> _expandedSubscriptions = <String, bool>{};
  final Set<String> _refreshingSubscriptions = <String>{};
  bool _isLoading = false;
  late int _lastRefreshToken;

  static const Color _borderColor = Color(0x14FFFFFF);
  static const Color _accentColor = Color(0xFFEF4444);

  @override
  void initState() {
    super.initState();
    _repository = SubscriptionRepository();
    _lastRefreshToken = widget.subscriptionsRefreshToken;
    unawaited(_loadSubscriptions());
  }

  @override
  void didUpdateWidget(covariant ProfileListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.subscriptionsRefreshToken != _lastRefreshToken) {
      _lastRefreshToken = widget.subscriptionsRefreshToken;
      unawaited(_loadSubscriptions());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSubscriptions() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final subs = await _repository.getAllSubscriptions();
      if (!mounted) return;
      setState(() {
        _subscriptions = subs;
        for (final sub in subs) {
          _expandedSubscriptions.putIfAbsent(sub.id, () => true);
        }
      });
      widget.onSubscriptionsChanged?.call(subs.isNotEmpty);
    } catch (e) {
      if (!mounted) return;
      debugPrint('[ProfileListView] Failed to load subscriptions: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshSubscription(VpnSubscription subscription) async {
    if (_refreshingSubscriptions.contains(subscription.id)) return;
    setState(() => _refreshingSubscriptions.add(subscription.id));
    try {
      final profiles = await _manager.fetchSubscription(subscription.url);
      if (profiles.isEmpty) {
        throw 'Подписка не вернула профили.';
      }

      final updated = subscription.copyWith(
        profiles: profiles,
        lastUpdated: DateTime.now(),
      );

      await _repository.updateSubscription(updated);
      await _loadSubscriptions();

      // Re-select the same index profile after refresh so selection is not lost.
      if (widget.selectedProfile != null) {
        final oldUri = widget.selectedProfile!.uri;
        // If old URI is still in the new list, keep it; otherwise pick same index.
        final oldIndex = subscription.profiles.indexOf(oldUri);
        final newIndex = (oldIndex >= 0 && oldIndex < profiles.length)
            ? oldIndex
            : (subscription.selectedIndex < profiles.length
                  ? subscription.selectedIndex
                  : 0);
        if (newIndex < profiles.length) {
          final newUri = profiles[newIndex];
          final profile = VpnProfile(
            name: _formatVlessSummary(newUri),
            uri: newUri,
          );
          widget.onProfileSelected(profile);
        }
      }

      if (!mounted) return;
      _toast('Подписка обновлена.', tone: NeuraToastTone.success);
    } catch (e) {
      if (!mounted) return;
      _toast('Не удалось обновить подписку: $e', tone: NeuraToastTone.error);
    } finally {
      if (mounted) {
        setState(() => _refreshingSubscriptions.remove(subscription.id));
      }
    }
  }

  Future<void> _deleteSubscription(VpnSubscription subscription) async {
    final confirm = await showNeuraDialog<bool>(
      context: context,
      builder: (context) => NeuraOverlayDialog(
        title: const Text('Удалить подписку?'),
        child: Text(
          'Удалить "${subscription.name}" с устройства? Это действие нельзя отменить.',
          style: TextStyle(color: Colors.white.withOpacity(0.78)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    try {
      await _repository.deleteSubscription(subscription.id);
      await _repository.deleteSubscriptionByUrl(subscription.url);
      await _loadSubscriptions();
    } catch (e) {
      if (!mounted) return;
      _toast('Не удалось удалить подписку: $e', tone: NeuraToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final children = <Widget>[];

    final selectedProfile = widget.selectedProfile;
    if (selectedProfile != null) {
      children.add(_buildCurrentSelection(selectedProfile));
    }

    if (widget.profiles.isNotEmpty) {
      // Standalone VLESS keys imported manually
      children.add(_buildSectionHeader('Конфигурации'));
      children.addAll(_buildRegularKeys());
    }

    if (_subscriptions.isNotEmpty) {
      children.add(_buildSectionHeader('Подписки'));
      children.addAll(_buildSubscriptions());
    }

    if (children.isEmpty) {
      return const Center(child: Text('Профилей нет'));
    }

    return ListView(
      controller: _scrollController,
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 8),
      children: children,
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: NeuraUi.neutral.withOpacity(0.5),
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  List<Widget> _buildRegularKeys() {
    return List.generate(widget.profiles.length, (index) {
      final profile = widget.profiles[index];
      final isSelected = widget.selectedProfile?.uri == profile.uri;

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isSelected ? _accentColor.withOpacity(0.14) : null,
            border: Border.all(
              color: isSelected
                  ? _accentColor.withOpacity(0.95)
                  : Colors.transparent,
              width: isSelected ? 1.3 : 0,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: _accentColor.withOpacity(0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            title: _configTitleMarquee(
              _formatVlessSummary(profile.uri),
              enabled: true,
            ),
            trailing: IconButton(
              tooltip: 'Удалить профиль',
              icon: const Icon(Icons.delete, size: 18, color: NeuraUi.danger),
              onPressed: () async {
                final confirm = await showNeuraDialog<bool>(
                  context: context,
                  builder: (context) => NeuraOverlayDialog(
                    title: const Text('Удалить профиль?'),
                    child: Text(
                      'Удалить "${profile.name}" с этого устройства?',
                      style: TextStyle(color: Colors.white.withOpacity(0.78)),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Отмена'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Удалить'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  widget.onDeleteProfile(profile);
                }
              },
            ),
            onTap: () => widget.onProfileSelected(profile),
          ),
        ),
      );
    });
  }

  List<Widget> _buildSubscriptions() {
    return List<Widget>.generate(_subscriptions.length, (index) {
      final subscription = _subscriptions[index];
      final isExpanded = _expandedSubscriptions[subscription.id] ?? true;
      return _buildSubscriptionCard(subscription, index, isExpanded);
    });
  }

  Widget _buildSubscriptionCard(
    VpnSubscription subscription,
    int subscriptionIndex,
    bool isExpanded,
  ) {
    final isRefreshing = _refreshingSubscriptions.contains(subscription.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.018),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _borderColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  setState(() {
                    _expandedSubscriptions[subscription.id] = !isExpanded;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _accentColor.withOpacity(0.11),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.cloud_download_outlined,
                          color: _accentColor,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Tooltip(
                          message: subscription.url,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _subscriptionDisplayName(
                                  subscription,
                                  subscriptionIndex,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${_profileCountLabel(subscription.profileCount)} · ${_lastUpdatedLabel(subscription.lastUpdated)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.48),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      _subscriptionAction(
                        tooltip: 'Обновить подписку',
                        onPressed: isRefreshing
                            ? null
                            : () => _refreshSubscription(subscription),
                        child: isRefreshing
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                  color: Colors.white54,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 18),
                      ),
                      _subscriptionAction(
                        tooltip: 'Удалить подписку',
                        onPressed: () => _deleteSubscription(subscription),
                        hoverColor: NeuraUi.danger.withOpacity(0.12),
                        child: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                      ),
                      _subscriptionAction(
                        tooltip: isExpanded ? 'Свернуть' : 'Развернуть',
                        onPressed: () {
                          setState(() {
                            _expandedSubscriptions[subscription.id] =
                                !isExpanded;
                          });
                        },
                        child: AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
                          duration: NeuraUi.fast,
                          curve: NeuraUi.curve,
                          child: const Icon(
                            Icons.expand_more_rounded,
                            size: 19,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ClipRect(
              child: AnimatedSize(
                duration: NeuraUi.normal,
                curve: NeuraUi.curve,
                alignment: Alignment.topCenter,
                child: isExpanded
                    ? Column(
                        children: [
                          Divider(
                            height: 1,
                            color: Colors.white.withOpacity(0.06),
                          ),
                          ..._buildSubscriptionProfiles(subscription),
                        ],
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSubscriptionProfiles(VpnSubscription subscription) {
    return List.generate(subscription.profiles.length, (index) {
      final vlessUri = subscription.profiles[index];
      final isSelected = widget.selectedProfile?.uri == vlessUri;

      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            final profile = VpnProfile(
              name: _formatVlessSummary(vlessUri),
              uri: vlessUri,
            );
            widget.onProfileSelected(profile);
          },
          hoverColor: Colors.white.withOpacity(0.035),
          child: AnimatedContainer(
            duration: NeuraUi.fast,
            curve: NeuraUi.curve,
            constraints: const BoxConstraints(minHeight: 58),
            decoration: BoxDecoration(
              color: isSelected
                  ? _accentColor.withOpacity(0.095)
                  : Colors.transparent,
              border: Border(
                bottom: BorderSide(color: Colors.white.withOpacity(0.045)),
              ),
            ),
            child: Stack(
              children: [
                if (isSelected)
                  const Positioned(
                    left: 0,
                    top: 9,
                    bottom: 9,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _accentColor,
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(3),
                          bottomRight: Radius.circular(3),
                        ),
                      ),
                      child: SizedBox(width: 3),
                    ),
                  ),
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.fromLTRB(14, 6, 12, 6),
                  title: _subscriptionProfileTitle(
                    vlessUri,
                    selected: isSelected,
                  ),
                  trailing: AnimatedSwitcher(
                    duration: NeuraUi.fast,
                    child: isSelected
                        ? Container(
                            key: const ValueKey('selected'),
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: _accentColor.withOpacity(0.16),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              color: _accentColor,
                              size: 16,
                            ),
                          )
                        : const SizedBox(
                            key: ValueKey('not-selected'),
                            width: 24,
                            height: 24,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildCurrentSelection(VpnProfile profile) {
    final subscription = _subscriptionForUri(profile.uri);
    final subscriptionIndex = subscription == null
        ? -1
        : _subscriptions.indexOf(subscription);
    final source = subscription == null
        ? 'Локальная конфигурация'
        : _subscriptionDisplayName(subscription, subscriptionIndex);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
            child: Text(
              'Текущий выбор',
              style: TextStyle(
                color: Colors.white.withOpacity(0.48),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: _accentColor.withOpacity(0.085),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _accentColor.withOpacity(0.2)),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _accentColor.withOpacity(0.16),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: _accentColor,
                    size: 17,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _vlessDisplayName(profile.uri),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$source · ${_vlessProtocolLine(profile.uri)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.52),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _subscriptionAction({
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget child,
    Color? hoverColor,
  }) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        splashRadius: 18,
        color: Colors.white54,
        hoverColor: hoverColor ?? Colors.white.withOpacity(0.06),
        icon: child,
      ),
    );
  }

  VpnSubscription? _subscriptionForUri(String uri) {
    for (final subscription in _subscriptions) {
      if (subscription.profiles.contains(uri)) return subscription;
    }
    return null;
  }

  String _subscriptionDisplayName(
    VpnSubscription subscription,
    int subscriptionIndex,
  ) {
    final name = subscription.name.trim();
    final host = Uri.tryParse(subscription.url)?.host.trim() ?? '';
    if (name.isNotEmpty && name.toLowerCase() != host.toLowerCase()) {
      return name;
    }

    final commonProfileName = _commonProfileName(subscription.profiles);
    if (commonProfileName.isNotEmpty) return commonProfileName;
    if (name.isNotEmpty) return name;
    return 'Подписка ${subscriptionIndex + 1}';
  }

  String _commonProfileName(List<String> profiles) {
    if (profiles.isEmpty) return '';
    final tokenLists = profiles
        .map(_vlessDisplayName)
        .map((name) => name.trim().split(RegExp(r'\s+')))
        .where((tokens) => tokens.isNotEmpty)
        .toList();
    if (tokenLists.isEmpty) return '';

    final shared = <String>[];
    for (var index = 0; index < tokenLists.first.length; index++) {
      final candidate = tokenLists.first[index];
      if (tokenLists.every(
        (tokens) =>
            tokens.length > index &&
            tokens[index].toLowerCase() == candidate.toLowerCase(),
      )) {
        shared.add(candidate);
      } else {
        break;
      }
    }

    while (shared.isNotEmpty &&
        !RegExp(r'[A-Za-zА-Яа-яЁё0-9]').hasMatch(shared.first)) {
      shared.removeAt(0);
    }
    while (shared.isNotEmpty && RegExp(r'^\d+$').hasMatch(shared.last)) {
      shared.removeLast();
    }
    return shared.join(' ').trim();
  }

  String _profileCountLabel(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    final noun = mod10 == 1 && mod100 != 11
        ? 'сервер'
        : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
        ? 'сервера'
        : 'серверов';
    return '$count $noun';
  }

  String _lastUpdatedLabel(DateTime value) {
    final difference = DateTime.now().difference(value);
    if (difference.isNegative || difference.inMinutes < 1) {
      return 'обновлено сейчас';
    }
    if (difference.inMinutes < 60) {
      return 'обновлено ${difference.inMinutes} мин назад';
    }
    if (difference.inHours < 24) {
      return 'обновлено ${difference.inHours} ч назад';
    }
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    return 'обновлено $day.$month.${value.year}';
  }
}
