import 'package:flutter/material.dart';
import '../models/vpn_subscription.dart';
import '../services/subscription_manager.dart';
import '../services/subscription_repository.dart';
import 'neura_ui.dart';

class SubscriptionManager extends StatefulWidget {
  const SubscriptionManager({Key? key}) : super(key: key);

  @override
  State<SubscriptionManager> createState() => _SubscriptionManagerState();
}

class _SubscriptionManagerState extends State<SubscriptionManager> {
  late SubscriptionRepository _repository;
  late SubscriptionService _manager;
  List<VpnSubscription> _subscriptions = [];
  VpnSubscription? _selectedSubscription;
  bool _isLoading = false;

  void _toast(String message, {NeuraToastTone tone = NeuraToastTone.neutral}) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(buildNeuraSnackBar(context, message, tone: tone));
  }

  @override
  void initState() {
    super.initState();
    _repository = SubscriptionRepository();
    _manager = SubscriptionService();
    _loadSubscriptions();
  }

  Future<void> _loadSubscriptions() async {
    setState(() => _isLoading = true);
    try {
      final subs = await _repository.getAllSubscriptions();
      final selected = await _repository.getSelectedSubscription();
      setState(() {
        _subscriptions = subs;
        _selectedSubscription = selected;
      });
    } catch (e) {
      _toast('Ошибка загрузки подписок: $e', tone: NeuraToastTone.error);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addSubscription() async {
    final result = await showNeuraDialog<(String, String)?>(
      context: context,
      builder: (context) => _AddSubscriptionDialog(),
    );

    if (result == null) return;
    final (url, name) = result;

    setState(() => _isLoading = true);
    try {
      // Проверяем валидность URL
      if (!_manager.isValidSubscriptionUrl(url)) {
        throw 'Неверный URL подписки';
      }

      // Загружаем профили из подписки
      final profiles = await _manager.fetchSubscription(url);
      if (profiles.isEmpty) {
        throw 'В подписке не найдено ни одного профиля VLESS';
      }

      // Создаём новую подписку
      final subscription = VpnSubscription(
        name: name,
        url: url,
        profiles: profiles,
        selectedIndex: 0,
      );

      final added = await _repository.addSubscription(subscription);
      if (added) {
        await _loadSubscriptions();
        _toast('Подписка добавлена', tone: NeuraToastTone.success);
      } else {
        throw 'Не удалось добавить подписку';
      }
    } catch (e) {
      _toast('Ошибка: $e', tone: NeuraToastTone.error);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshSubscription(VpnSubscription subscription) async {
    setState(() => _isLoading = true);
    try {
      // Перезагружаем профили из подписки
      final profiles = await _manager.fetchSubscription(subscription.url);
      if (profiles.isEmpty) {
        throw 'В подписке не найдено ни одного профиля VLESS';
      }

      // Обновляем подписку
      final updated = subscription.copyWith(
        profiles: profiles,
        lastUpdated: DateTime.now(),
      );

      final success = await _repository.updateSubscription(updated);
      if (success) {
        await _loadSubscriptions();
        _toast('Подписка обновлена', tone: NeuraToastTone.success);
      }
    } catch (e) {
      _toast('Ошибка обновления: $e', tone: NeuraToastTone.error);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteSubscription(VpnSubscription subscription) async {
    final confirm = await showNeuraDialog<bool>(
      context: context,
      builder: (context) => NeuraOverlayDialog(
        title: const Text('Удалить подписку?'),
        child: Text(
          'Подписка "${subscription.name}" будет удалена безвозвратно',
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
      _toast('Подписка удалена', tone: NeuraToastTone.success);
    } catch (e) {
      _toast('Ошибка: $e', tone: NeuraToastTone.error);
    }
  }

  Future<void> _selectProfile(
    VpnSubscription subscription,
    int profileIndex,
  ) async {
    try {
      final updated = subscription.copyWith(selectedIndex: profileIndex);
      await _repository.updateSubscription(updated);
      await _repository.setSelectedSubscription(subscription.id);
      await _loadSubscriptions();

      _toast(
        'Профиль "${updated.selectedProfile}" выбран',
        tone: NeuraToastTone.success,
      );
    } catch (e) {
      _toast('Ошибка: $e', tone: NeuraToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Подписки'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _isLoading ? null : _addSubscription,
            tooltip: 'Добавить подписку',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _subscriptions.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_off, size: 64, color: NeuraUi.neutral.withOpacity(0.7)),
                  const SizedBox(height: 16),
                  const Text('Нет подписок'),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _addSubscription,
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить подписку'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _subscriptions.length,
              itemBuilder: (context, index) {
                final subscription = _subscriptions[index];
                final isSelected = _selectedSubscription?.id == subscription.id;

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: ExpansionTile(
                    leading: Icon(
                      isSelected ? Icons.check_circle : Icons.cloud_download,
                      color: isSelected ? NeuraUi.success : NeuraUi.neutral.withOpacity(0.6),
                    ),
                    title: Text(subscription.name),
                    subtitle: Text('Профилей: ${subscription.profileCount}'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'URL: ${subscription.url}',
                              style: const TextStyle(fontSize: 12),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Обновлено: ${subscription.formattedLastUpdate}',
                              style: TextStyle(
                                fontSize: 12,
                                color: NeuraUi.neutral.withOpacity(0.55),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Выберите профиль:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            ...List.generate(
                              subscription.profiles.length,
                              (i) => ListTile(
                                leading: Radio(
                                  value: i,
                                  groupValue: subscription.selectedIndex,
                                  onChanged: (_) =>
                                      _selectProfile(subscription, i),
                                ),
                                title: Text(
                                  subscription.profiles[i],
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: subscription.selectedIndex == i
                                    ? const Icon(
                                        Icons.check,
                                        color: NeuraUi.success,
                                      )
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: () =>
                                      _refreshSubscription(subscription),
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Обновить'),
                                ),
                                ElevatedButton.icon(
                                  onPressed: () =>
                                      _deleteSubscription(subscription),
                                  icon: const Icon(Icons.delete),
                                  label: const Text('Удалить'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: NeuraUi.danger,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// Диалог для добавления новой подписки
class _AddSubscriptionDialog extends StatefulWidget {
  @override
  State<_AddSubscriptionDialog> createState() => _AddSubscriptionDialogState();
}

class _AddSubscriptionDialogState extends State<_AddSubscriptionDialog> {
  late TextEditingController _urlController;
  late TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _nameController = TextEditingController();
    _urlController.addListener(() => setState(() {}));
    _nameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isValid =
        _urlController.text.isNotEmpty && _nameController.text.isNotEmpty;

    return NeuraOverlayDialog(
      title: const Text('Добавить подписку'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: isValid
              ? () {
                  Navigator.pop(context, (
                    _urlController.text,
                    _nameController.text,
                  ));
                }
              : null,
          child: const Text('Добавить'),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Имя подписки',
                hintText: 'Например: 3X-UI Server',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'URL подписки (base64)',
                hintText: 'https://example.com/subscribe?token=...',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
