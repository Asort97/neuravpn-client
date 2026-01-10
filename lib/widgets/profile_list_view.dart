import 'dart:async';

import 'package:flutter/material.dart';

import '../models/vpn_profile.dart';
import '../models/vpn_subscription.dart';
import '../services/subscription_manager.dart';
import '../services/subscription_repository.dart';
import '../vless/vless_parser.dart';

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
        fontSize: 13,
        color: Colors.white,
        fontWeight: enabled ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }

  List<String> _buildVlessTags(String uri) {
    final parsed = parseVlessUri(uri);
    if (parsed == null) return const [];

    final tags = <String>['VLESS'];

    final transport = (parsed.type?.trim().isNotEmpty ?? false)
        ? parsed.type!.trim()
        : 'tcp';
    tags.add(transport.toUpperCase());

    final security = parsed.security?.trim().toLowerCase() ?? '';
    if (security == 'reality') {
      tags.add('REALITY');
    } else if (security == 'tls') {
      tags.add('TLS');
    } else {
      tags.add('PLAIN');
    }

    final flow = parsed.flow?.trim();
    if (flow != null && flow.isNotEmpty) {
      tags.add(flow.toUpperCase());
    }

    return tags;
  }

  Widget _tagPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withOpacity(0.08),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withOpacity(0.85),
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
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
  List<VpnSubscription> _subscriptions = const [];
  final Map<String, bool> _expandedSubscriptions = <String, bool>{};
  bool _isLoading = false;
  late int _lastRefreshToken;

  bool get _isMobile =>
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS;
  static const Color _cardColor = Color(0xFF1A1A1A);
  static const Color _surfaceColor = Color(0xFF2A2A2A);
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

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Подписка обновлена.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось обновить подписку: $e')),
      );
    }
  }

  Future<void> _deleteSubscription(VpnSubscription subscription) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить подписку?'),
        content: Text(
          'Удалить "${subscription.name}" с устройства? Это действие нельзя отменить.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Удалить',
              style: TextStyle(color: Colors.red),
            ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить подписку: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final children = <Widget>[];

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

    return ListView(children: children);
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Colors.grey[500],
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  List<Widget> _buildRegularKeys() {
    final scheme = Theme.of(context).colorScheme;
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
              color: isSelected ? _accentColor.withOpacity(0.95) : Colors.transparent,
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
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: _surfaceColor,
              child: const Icon(Icons.vpn_key, size: 16, color: Colors.white70),
            ),
            title: _configTitleMarquee(_formatVlessSummary(profile.uri), enabled: true),
            trailing: IconButton(
              tooltip: 'Удалить профиль',
              icon: const Icon(Icons.delete, size: 18, color: Colors.redAccent),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Удалить профиль?'),
                    content: Text('Удалить "${profile.name}" с этого устройства?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Отмена'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text(
                          'Удалить',
                          style: TextStyle(color: Colors.red),
                        ),
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
    return _subscriptions.map((subscription) {
      final isExpanded = _expandedSubscriptions[subscription.id] ?? true;
      return _buildSubscriptionCard(subscription, isExpanded);
    }).toList();
  }

  Widget _buildSubscriptionCard(VpnSubscription subscription, bool isExpanded) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border(
            top: BorderSide(color: _borderColor),
            bottom: BorderSide(color: _borderColor),
          ),
        ),
        child: Column(
          children: [
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 2,
              ),
              leading: Icon(Icons.cloud_download, color: scheme.primary),
              title: Text(
                subscription.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                onPressed: () {
                  setState(() {
                    _expandedSubscriptions[subscription.id] = !isExpanded;
                  });
                },
              ),
              onTap: () {
                setState(() {
                  _expandedSubscriptions[subscription.id] = !isExpanded;
                });
              },
            ),
            if (isExpanded) ...[
              const Divider(height: 1, indent: 12, endIndent: 12),
              ..._buildSubscriptionProfiles(subscription),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: _isMobile
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            tooltip: 'Обновить',
                            onPressed: () => _refreshSubscription(subscription),
                            icon: const Icon(Icons.refresh),
                          ),
                          IconButton(
                            tooltip: 'Удалить',
                            onPressed: () => _deleteSubscription(subscription),
                            icon: const Icon(Icons.delete),
                            color: Colors.redAccent,
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _refreshSubscription(subscription),
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Обновить'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: BorderSide(
                                color: Colors.white.withOpacity(0.18),
                              ),
                              backgroundColor: _surfaceColor,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _deleteSubscription(subscription),
                            icon: const Icon(Icons.delete, size: 18),
                            label: const Text('Удалить'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                color: Colors.redAccent.withOpacity(0.6),
                              ),
                              backgroundColor: Colors.redAccent.withOpacity(0.2),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSubscriptionProfiles(VpnSubscription subscription) {
    final scheme = Theme.of(context).colorScheme;
    return List.generate(subscription.profiles.length, (index) {
      final vlessUri = subscription.profiles[index];
      final isSelected = widget.selectedProfile?.uri == vlessUri;

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isSelected ? _accentColor.withOpacity(0.14) : null,
            border: Border.all(
              color: isSelected ? _accentColor.withOpacity(0.95) : Colors.transparent,
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
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: _surfaceColor,
              child: const Icon(Icons.public, size: 16, color: Colors.white70),
            ),
            title: _subscriptionProfileTitle(vlessUri, selected: true),
            onTap: () {
              final profile = VpnProfile(
                name: _formatVlessSummary(vlessUri),
                uri: vlessUri,
              );
              widget.onProfileSelected(profile);
            },
          ),
        ),
      );
    });
  }
}
