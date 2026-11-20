import 'dart:async';

import 'package:flutter/material.dart';

import '../models/vpn_profile.dart';
import '../models/vpn_subscription.dart';
import '../services/subscription_manager.dart';
import '../services/subscription_repository.dart';
import '../services/profile_availability.dart';
import '../vless/proxy_parser.dart';
import 'neura_motion.dart';
import 'neura_ui.dart';
import 'profile_availability_indicator.dart';

class ProfileListView extends StatefulWidget {
  const ProfileListView({
    super.key,
    required this.profiles,
    required this.selectedProfile,
    required this.onProfileSelected,
    required this.onDeleteProfile,
    this.subscriptionsRefreshToken = 0,
    this.onSubscriptionsChanged,
    this.mobile = false,
    this.checkBackend,
    this.pendingProfileUri,
  });

  final List<VpnProfile> profiles;
  final VpnProfile? selectedProfile;
  final ValueChanged<VpnProfile> onProfileSelected;
  final ValueChanged<VpnProfile> onDeleteProfile;
  final int subscriptionsRefreshToken;
  final ValueChanged<bool>? onSubscriptionsChanged;
  final bool mobile;
  final ProfileCheckBackend? checkBackend;

  /// Profile the user just tapped while the app is still applying it. Shown
  /// as selected right away, with a spinner instead of the check mark.
  final String? pendingProfileUri;

  @override
  State<ProfileListView> createState() => _ProfileListViewState();
}

/// Display text for one stored profile URI, computed once per URI.
///
/// Parsing a server JSON profile decodes base64 and JSON and deep-copies its
/// outbounds (about half a millisecond each), so the list must never parse
/// URIs while building rows.
class ProfileLabel {
  const ProfileLabel({
    required this.name,
    required this.summary,
    required this.detail,
  });

  factory ProfileLabel.fromUri(String uri) {
    final parsed = parseProxyUri(uri);
    if (parsed == null) {
      return const ProfileLabel(
        name: 'Неподдерживаемый профиль',
        summary: 'Неподдерживаемый профиль',
        detail: 'Формат не распознан',
      );
    }
    final tag = parsed.tag?.trim() ?? '';
    final sni = parsed.sni?.trim() ?? '';
    final host = parsed.host.trim();
    final name = tag.isNotEmpty
        ? _safeDecode(tag)
        : sni.isNotEmpty
        ? sni
        : host.isNotEmpty
        ? host
        : _safeDecode(uri);
    final summary = tag.isNotEmpty
        ? tag
        : sni.isNotEmpty
        ? sni
        : host.isNotEmpty
        ? host
        : uri;
    return ProfileLabel(name: name, summary: summary, detail: _detail(parsed));
  }

  /// Title shown in the list.
  final String name;

  /// Legacy name stored in [VpnProfile.name] when a profile is selected.
  final String summary;

  /// Protocol line, e.g. "VLESS · XHTTP · Reality" or "Автовыбор · 5 серверов".
  final String detail;

  static String _detail(ProxyLink link) {
    if (link is XrayProfile) {
      final servers = (link.config['outbounds'] as List)
          .whereType<Map>()
          .where((o) => o['protocol'] == 'vless' || o['protocol'] == 'hysteria')
          .toList();
      if (!link.isAutomatic) {
        return servers.isNotEmpty && servers.first['protocol'] == 'hysteria'
            ? 'Hysteria 2'
            : 'VLESS';
      }
      return servers.length > 1
          ? 'Автовыбор · ${serverCountLabel(servers.length)}'
          : 'Автовыбор';
    }
    if (link is Hysteria2Link) return 'Hysteria 2';
    final parts = <String>[link.protocolLabel];
    final transport = link.type?.trim().toLowerCase() ?? '';
    parts.add(switch (transport) {
      '' || 'tcp' || 'raw' => 'TCP',
      'ws' => 'WebSocket',
      'grpc' => 'gRPC',
      'xhttp' => 'XHTTP',
      'splithttp' => 'SplitHTTP',
      'httpupgrade' => 'HTTPUpgrade',
      'kcp' || 'mkcp' => 'mKCP',
      _ => transport.toUpperCase(),
    });
    if (link.isReality) {
      parts.add('Reality');
    } else if (link.isTls) {
      parts.add('TLS');
    }
    return parts.join(' · ');
  }

  static String _safeDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }
}

/// "1 сервер", "3 сервера", "5 серверов".
String serverCountLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  final noun = mod10 == 1 && mod100 != 11
      ? 'сервер'
      : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
      ? 'сервера'
      : 'серверов';
  return '$count $noun';
}

class _ProfileListViewState extends State<ProfileListView> {
  void _toast(String message, {NeuraToastTone tone = NeuraToastTone.neutral}) {
    showNeuraToast(context, message, tone: tone);
  }

  final Map<String, ProfileLabel> _labels = <String, ProfileLabel>{};

  ProfileLabel _labelFor(String uri) =>
      _labels[uri] ??= ProfileLabel.fromUri(uri);

  /// Drops labels of profiles that left the list (refresh, delete).
  void _pruneLabels() {
    if (_labels.isEmpty) return;
    final live = <String>{
      ...widget.profiles.map((profile) => profile.uri),
      ..._subscriptions.expand((subscription) => subscription.profiles),
    };
    _labels.removeWhere((uri, _) => !live.contains(uri));
  }

  String _formatVlessSummary(String uri) => _labelFor(uri).summary;

  String _vlessDisplayName(String uri) => _labelFor(uri).name;

  String? get _effectiveSelectedUri =>
      widget.pendingProfileUri ?? widget.selectedProfile?.uri;

  Widget _profileTitle(String uri) {
    final label = _labelFor(uri);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label.detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.66),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// Trailing check for the selected row; a spinner while it is being applied.
  Widget _selectionMark(String uri) {
    final selected = _effectiveSelectedUri == uri;
    final pending = selected && widget.pendingProfileUri == uri;
    final Widget child;
    if (pending) {
      child = const SizedBox(
        key: ValueKey('pending'),
        width: 24,
        height: 24,
        child: Padding(
          padding: EdgeInsets.all(4),
          child: CircularProgressIndicator(strokeWidth: 2, color: _accentColor),
        ),
      );
    } else if (selected) {
      child = Container(
        key: const ValueKey('selected'),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: _accentColor.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, color: _accentColor, size: 16),
      );
    } else {
      child = const SizedBox(
        key: ValueKey('not-selected'),
        width: 24,
        height: 24,
      );
    }
    return AnimatedSwitcher(duration: NeuraUi.fast, child: child);
  }

  late final SubscriptionRepository _repository;
  final SubscriptionService _manager = SubscriptionService();
  final NeuraSmoothScrollController _scrollController =
      NeuraSmoothScrollController();
  List<VpnSubscription> _subscriptions = const [];
  final Map<String, bool> _expandedSubscriptions = <String, bool>{};
  final Set<String> _refreshingSubscriptions = <String>{};
  bool _isLoading = false;
  bool _loadedOnce = false;
  late int _lastRefreshToken;
  ProfileAvailabilityController? _availability;
  Timer? _availabilityRefresh;

  void _checksChanged() {
    if (mounted) setState(() {});
  }

  void _syncCheckProfiles() => _availability?.setProfiles([
    ...widget.profiles.map((profile) => profile.uri),
    ..._subscriptions.expand((subscription) => subscription.profiles),
  ]);

  Widget _availabilityIcon(String uri) =>
      ProfileAvailabilityIndicator(result: _availability!.resultFor(uri));

  Future<void> _showMobileActions(VpnSubscription subscription) async {
    final action = await showNeuraBottomSheet<String>(
      context: context,
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                _subscriptionDisplayName(
                  subscription,
                  _subscriptions.indexOf(subscription),
                ),
              ),
              subtitle: Text(
                '${_profileCountLabel(subscription.profileCount)} · '
                '${_lastUpdatedLabel(subscription.lastUpdated)}',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('Обновить'),
              onTap: () => Navigator.pop(context, 'refresh'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Переименовать'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: NeuraUi.danger,
              ),
              title: const Text('Удалить'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'refresh':
        await _refreshSubscription(subscription);
      case 'rename':
        await _renameSubscription(subscription);
      case 'delete':
        await _deleteSubscription(subscription);
    }
  }

  Future<void> _renameSubscription(VpnSubscription subscription) async {
    final name = await showNeuraBottomSheet<String>(
      context: context,
      builder: (context) =>
          _SubscriptionNameEditor(initialName: subscription.name),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    // Refresh may have completed while the editor was open. Keep its profiles.
    final current = _subscriptions
        .where((item) => item.id == subscription.id)
        .firstOrNull;
    if (current == null) return;
    final saved = await _repository.updateSubscription(
      current.copyWith(name: name.trim()),
    );
    if (!mounted) return;
    if (saved) {
      await _loadSubscriptions();
    } else {
      _toast('Не удалось сохранить название.', tone: NeuraToastTone.error);
    }
  }

  static const Color _borderColor = Color(0x14FFFFFF);
  static const Color _accentColor = Color(0xFFEF4444);

  @override
  void initState() {
    super.initState();
    _repository = SubscriptionRepository();
    if (widget.checkBackend != null) {
      _availability = ProfileAvailabilityController(widget.checkBackend!)
        ..addListener(_checksChanged);
      _syncCheckProfiles();
      _availabilityRefresh = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _checksChanged(),
      );
    }
    _lastRefreshToken = widget.subscriptionsRefreshToken;
    unawaited(_loadSubscriptions());
  }

  @override
  void didUpdateWidget(covariant ProfileListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCheckProfiles();
    if (!identical(widget.profiles, oldWidget.profiles)) _pruneLabels();
    if (widget.subscriptionsRefreshToken != _lastRefreshToken) {
      _lastRefreshToken = widget.subscriptionsRefreshToken;
      unawaited(_loadSubscriptions());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _availabilityRefresh?.cancel();
    _availability?.removeListener(_checksChanged);
    _availability?.dispose();
    super.dispose();
  }

  Future<void> _loadSubscriptions() async {
    if (!mounted) return;
    // Reloads after refresh/rename keep the list on screen: swapping it for a
    // spinner flashed the whole card and lost the scroll position.
    if (!_loadedOnce) setState(() => _isLoading = true);
    try {
      final subs = await _repository.getAllSubscriptions();
      if (!mounted) return;
      setState(() {
        _subscriptions = subs;
        _loadedOnce = true;
        _pruneLabels();
        _syncCheckProfiles();
        for (final sub in subs) {
          _expandedSubscriptions.putIfAbsent(sub.id, () => true);
        }
      });
      widget.onSubscriptionsChanged?.call(subs.isNotEmpty);
    } catch (e) {
      if (!mounted) return;
      debugPrint('[ProfileListView] Failed to load subscriptions: $e');
    } finally {
      if (mounted && _isLoading) setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshSubscription(VpnSubscription subscription) async {
    if (_refreshingSubscriptions.contains(subscription.id)) return;
    setState(() => _refreshingSubscriptions.add(subscription.id));
    try {
      final requestedAt = DateTime.now();
      final profiles = await _manager.fetchSubscription(subscription.url);
      if (profiles.isEmpty) {
        throw 'Подписка не вернула профили.';
      }

      final updated = subscription.copyWith(
        profiles: profiles,
        lastUpdated: requestedAt,
      );

      final saved = await _repository.updateSubscription(updated);
      await _loadSubscriptions();
      if (!saved) return;

      // Re-select the same index profile after refresh so selection is not lost.
      if (widget.selectedProfile != null &&
          (!widget.mobile ||
              subscription.profiles.contains(widget.selectedProfile!.uri))) {
        final oldUri = widget.selectedProfile!.uri;
        // If old URI is still in the new list, keep it; otherwise pick same index.
        final oldIndex = subscription.profiles.indexOf(oldUri);
        final newIndex = (oldIndex >= 0 && oldIndex < profiles.length)
            ? oldIndex
            : (subscription.selectedIndex < profiles.length
                  ? subscription.selectedIndex
                  : 0);
        if (newIndex < profiles.length) {
          final newUri = widget.mobile && profiles.contains(oldUri)
              ? oldUri
              : profiles[newIndex];
          final profile = VpnProfile(
            name: _formatVlessSummary(newUri),
            uri: newUri,
          );
          widget.onProfileSelected(profile);
        }
      }

      if (!mounted) return;
      _toast('Подписка обновлена.', tone: NeuraToastTone.success);
    } on SubscriptionDeviceLimitException catch (error) {
      await _repository.invalidateAccess(subscription.url, error.message);
      await _loadSubscriptions();
      if (!mounted) return;
      _toast(error.message, tone: NeuraToastTone.error);
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
          style: TextStyle(color: Colors.white.withValues(alpha: 0.78)),
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
    if (_isLoading && !_loadedOnce) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final children = <Widget>[];

    final selectedUri = _effectiveSelectedUri;
    if (selectedUri != null) {
      children.add(_buildCurrentSelection(selectedUri));
    }

    if (widget.profiles.isNotEmpty) {
      // Standalone VLESS keys imported manually
      children.add(
        _buildSectionHeader(
          'Конфигурации',
          trailing: _availability == null
              ? null
              : _checkAction(
                  scope: _localScope,
                  uris: [for (final profile in widget.profiles) profile.uri],
                ),
        ),
      );
      children.addAll(_buildRegularKeys());
    }

    if (_subscriptions.isNotEmpty) {
      children.add(_buildSectionHeader('Подписки'));
      children.addAll(_buildSubscriptions());
    }

    if (widget.profiles.isEmpty && _subscriptions.isEmpty) {
      children.add(_buildEmptyHint());
    }

    return ListView(
      controller: _scrollController,
      physics: widget.mobile ? const BouncingScrollPhysics() : null,
      keyboardDismissBehavior: widget.mobile
          ? ScrollViewKeyboardDismissBehavior.onDrag
          : ScrollViewKeyboardDismissBehavior.manual,
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 8),
      children: children,
    );
  }

  static const String _localScope = '__local__';

  /// Small per-group check button: probes only the servers of this group.
  /// While its own run is going it shows progress and stops the run.
  Widget _checkAction({required String scope, required List<String> uris}) {
    final checks = _availability!;
    final mine = checks.running && checks.runningScope == scope;
    final elsewhere = checks.running && !mine;
    final progress = checks.total == 0 ? null : checks.completed / checks.total;
    return _subscriptionAction(
      key: ValueKey('check-$scope'),
      tooltip: mine
          ? (checks.cancelling
                ? 'Останавливаем проверку'
                : 'Остановить проверку')
          : 'Проверить серверы',
      onPressed: uris.isEmpty || elsewhere || checks.cancelling
          ? null
          : () {
              if (mine) {
                NeuraHaptics.light();
                unawaited(checks.cancel());
                return;
              }
              NeuraHaptics.light();
              if (scope != _localScope) {
                setState(() => _expandedSubscriptions[scope] = true);
              }
              _syncCheckProfiles();
              unawaited(checks.checkAll(uris, scope: scope));
            },
      child: mine
          ? Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    value: progress == 0 ? null : progress,
                    strokeWidth: 2.2,
                    color: _accentColor,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                const Icon(Icons.stop_rounded, size: 14, color: Colors.white),
              ],
            )
          : const Icon(Icons.speed_rounded, size: 21),
    );
  }

  /// "работают 12 из 20" after a check, or live progress while one runs.
  String? _checkSummary(String scope, List<String> uris) {
    final checks = _availability;
    if (checks == null || uris.isEmpty) return null;
    if (checks.running && checks.runningScope == scope) {
      return 'проверено ${checks.completed} из ${checks.total}';
    }
    var judged = 0;
    var working = 0;
    for (final uri in uris) {
      final status = checks.resultFor(uri).status;
      if (status == ProfileAvailability.available) {
        working++;
        judged++;
      } else if (status == ProfileAvailability.unavailable ||
          status == ProfileAvailability.error) {
        judged++;
      }
    }
    if (judged == 0) return null;
    return 'работают $working из $judged';
  }

  Widget _buildSectionHeader(String title, {Widget? trailing}) {
    final label = Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: NeuraUi.neutral.withValues(alpha: 0.62),
        fontWeight: FontWeight.bold,
      ),
    );
    if (trailing == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: label,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
      child: Row(
        children: [
          Expanded(child: label),
          trailing,
        ],
      ),
    );
  }

  List<Widget> _buildRegularKeys() {
    return List.generate(widget.profiles.length, (index) {
      final profile = widget.profiles[index];
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: _profileRow(
          uri: profile.uri,
          radius: BorderRadius.circular(8),
          onTap: () => widget.onProfileSelected(profile),
          actions: [
            IconButton(
              tooltip: 'Удалить профиль',
              icon: const Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: NeuraUi.danger,
              ),
              onPressed: () => _confirmDeleteProfile(profile),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _confirmDeleteProfile(VpnProfile profile) async {
    final confirm = await showNeuraDialog<bool>(
      context: context,
      builder: (context) => NeuraOverlayDialog(
        title: const Text('Удалить профиль?'),
        child: Text(
          'Удалить «${_vlessDisplayName(profile.uri)}» с этого устройства?',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.78)),
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
    if (confirm == true) widget.onDeleteProfile(profile);
  }

  /// One selectable profile row, shared by local keys and subscriptions so
  /// both read the same: tint plus check mark when selected.
  Widget _profileRow({
    required String uri,
    required VoidCallback onTap,
    List<Widget> actions = const [],
    BorderRadius? radius,
    bool divider = false,
  }) {
    final selected = _effectiveSelectedUri == uri;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: radius == null ? Clip.none : Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: Colors.white.withValues(alpha: 0.035),
          child: AnimatedContainer(
            duration: NeuraUi.fast,
            curve: NeuraUi.curve,
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            decoration: BoxDecoration(
              color: selected
                  ? _accentColor.withValues(alpha: 0.12)
                  : Colors.transparent,
              border: divider
                  ? Border(
                      bottom: BorderSide(
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                    )
                  : null,
            ),
            child: Row(
              children: [
                Expanded(child: _profileTitle(uri)),
                const SizedBox(width: 6),
                if (_availability != null) _availabilityIcon(uri),
                ...actions,
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: _selectionMark(uri),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
        decoration: widget.mobile
            ? const BoxDecoration()
            : BoxDecoration(
                color: Colors.white.withValues(alpha: 0.018),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _borderColor),
              ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _toggleExpanded(subscription.id, isExpanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _accentColor.withValues(alpha: 0.11),
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
                                subscription.error ??
                                [
                                  _profileCountLabel(subscription.profileCount),
                                  _checkSummary(
                                        subscription.id,
                                        subscription.profiles,
                                      ) ??
                                      _lastUpdatedLabel(
                                        subscription.lastUpdated,
                                      ),
                                ].join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.62),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_availability != null)
                        _checkAction(
                          scope: subscription.id,
                          uris: subscription.profiles,
                        ),
                      if (widget.mobile)
                        _subscriptionAction(
                          tooltip: isRefreshing
                              ? 'Подписка обновляется'
                              : 'Действия с подпиской',
                          onPressed: isRefreshing
                              ? null
                              : () => _showMobileActions(subscription),
                          child: isRefreshing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _accentColor,
                                  ),
                                )
                              : const Icon(Icons.more_horiz_rounded),
                        ),
                      if (!widget.mobile)
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
                      if (!widget.mobile)
                        _subscriptionAction(
                          tooltip: 'Удалить подписку',
                          onPressed: () => _deleteSubscription(subscription),
                          hoverColor: NeuraUi.danger.withValues(alpha: 0.12),
                          child: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                          ),
                        ),
                      _subscriptionAction(
                        tooltip: isExpanded ? 'Свернуть' : 'Развернуть',
                        onPressed: () =>
                            _toggleExpanded(subscription.id, isExpanded),
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
                            color: Colors.white.withValues(alpha: 0.06),
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
      final uri = subscription.profiles[index];
      return _profileRow(
        uri: uri,
        divider: index < subscription.profiles.length - 1,
        onTap: () => widget.onProfileSelected(
          VpnProfile(name: _formatVlessSummary(uri), uri: uri),
        ),
      );
    });
  }

  Widget _buildCurrentSelection(String uri) {
    final subscription = _subscriptionForUri(uri);
    final subscriptionIndex = subscription == null
        ? -1
        : _subscriptions.indexOf(subscription);
    final source = subscription == null
        ? 'Локальная конфигурация'
        : 'Подписка «${_subscriptionDisplayName(subscription, subscriptionIndex)}»';
    final pending = widget.pendingProfileUri == uri;
    final label = _labelFor(uri);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
            child: Text(
              pending ? 'Применяем выбор…' : 'Текущий выбор',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Semantics(
            liveRegion: true,
            label: pending
                ? 'Применяем ${label.name}'
                : 'Выбран ${label.name}, ${label.detail}, $source',
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: _accentColor.withValues(alpha: 0.085),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _accentColor.withValues(alpha: 0.22)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _accentColor.withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                    ),
                    child: AnimatedSwitcher(
                      duration: NeuraUi.fast,
                      child: pending
                          ? const Padding(
                              key: ValueKey('pending'),
                              padding: EdgeInsets.all(6),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _accentColor,
                              ),
                            )
                          : const Icon(
                              Icons.check_rounded,
                              key: ValueKey('selected'),
                              color: _accentColor,
                              size: 17,
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          label.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          source,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.58),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _subscriptionAction({
    Key? key,
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget child,
    Color? hoverColor,
  }) {
    return SizedBox(
      key: key,
      width: widget.mobile ? 48 : 34,
      height: widget.mobile ? 48 : 34,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        splashRadius: widget.mobile ? 22 : 18,
        color: Colors.white70,
        hoverColor: hoverColor ?? Colors.white.withValues(alpha: 0.06),
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

  String _profileCountLabel(int count) => serverCountLabel(count);

  void _toggleExpanded(String id, bool isExpanded) {
    NeuraHaptics.selection();
    setState(() => _expandedSubscriptions[id] = !isExpanded);
  }

  Widget _buildEmptyHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 20),
      child: Column(
        children: [
          Icon(
            Icons.vpn_key_outlined,
            size: 28,
            color: Colors.white.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          const Text(
            'Пока нет профилей',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Нажмите «+», чтобы добавить подписку или ключ, '
            'или отсканируйте QR-код.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.66),
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
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

class _SubscriptionNameEditor extends StatefulWidget {
  const _SubscriptionNameEditor({required this.initialName});
  final String initialName;

  @override
  State<_SubscriptionNameEditor> createState() =>
      _SubscriptionNameEditorState();
}

class _SubscriptionNameEditorState extends State<_SubscriptionNameEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Название подписки',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value);
          },
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () {
            if (_name.text.trim().isNotEmpty) {
              Navigator.pop(context, _name.text);
            }
          },
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
}
