import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/calls/max_audio_call.dart';
import '../../data/local/database.dart';
import '../../data/max/models/contact.dart';
import '../../state/providers.dart';
import 'audio_call_screen.dart';

/// История звонков + первый рабочий сценарий исходящего аудиозвонка.
/// Входящие и видео добавим после проверки end-to-end на iPhone 5s.
class CallsListScreen extends ConsumerWidget {
  const CallsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calls = ref.watch(_callsLogProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Звонки'),
        actions: [
          IconButton(
            tooltip: 'Создать звонок',
            onPressed: () => _startNewCall(context, ref),
            icon: const Icon(Icons.add_call),
          ),
        ],
      ),
      body: calls.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Ошибка: $e')),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.call_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'История звонков пуста',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Нажмите +, выберите контакт MAX и сделайте первый аудиозвонок.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 0, indent: 72),
            itemBuilder: (_, i) {
              final row = rows[i];
              final peerId = (row['peer_id'] as num?)?.toInt();
              final peerName = (row['peer_name'] as String?) ??
                  (peerId == null ? 'Контакт' : 'Контакт $peerId');
              return ListTile(
                leading: CircleAvatar(
                  child: Text(
                    peerName.isNotEmpty ? peerName[0].toUpperCase() : '?',
                  ),
                ),
                title: Text(peerName),
                subtitle: Text(_formatCallRow(row)),
                trailing: IconButton(
                  tooltip: 'Позвонить снова',
                  onPressed: peerId == null
                      ? null
                      : () => _openCall(
                            context,
                            ref,
                            peerId: peerId,
                            peerName: peerName,
                          ),
                  icon: const Icon(Icons.call),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _startNewCall(context, ref),
        tooltip: 'Новый звонок',
        child: const Icon(Icons.add_call),
      ),
    );
  }

  Future<void> _startNewCall(BuildContext context, WidgetRef ref) async {
    try {
      final contactsRepo = await ref.read(contactsRepositoryProvider.future);
      final contacts = await contactsRepo.listLocal();
      if (!context.mounted) return;
      if (contacts.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Сначала добавьте хотя бы один контакт MAX во вкладке «Контакты».',
            ),
          ),
        );
        return;
      }

      contacts.sort((a, b) => _contactName(a).compareTo(_contactName(b)));
      final selected = await showModalBottomSheet<MaxContact>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.65,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: Text(
                    'Кому позвонить?',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    itemCount: contacts.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 0, indent: 72),
                    itemBuilder: (_, i) {
                      final c = contacts[i];
                      final name = _contactName(c);
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : '?',
                          ),
                        ),
                        title: Text(name),
                        subtitle: c.phone == null ? null : Text(c.phone!),
                        trailing: const Icon(Icons.call_outlined),
                        onTap: () => Navigator.of(sheetContext).pop(c),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (!context.mounted || selected == null) return;
      await _openCall(
        context,
        ref,
        peerId: selected.id,
        peerName: _contactName(selected),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть список контактов: $e')),
      );
    }
  }

  Future<void> _openCall(
    BuildContext context,
    WidgetRef ref, {
    required int peerId,
    required String peerName,
  }) async {
    final result = await Navigator.of(context).push<MaxAudioCallResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AudioCallScreen(
          peerUserId: peerId,
          peerName: peerName,
        ),
      ),
    );
    if (result == null) return;

    try {
      final db = await ref.read(appDatabaseProvider.future);
      await _ensureCallsTable(db);
      await db.raw.insert('calls', <String, Object?>{
        'peer_id': peerId,
        'peer_name': peerName,
        'direction': 'outgoing',
        'missed': 0,
        'started_at_ms': result.startedAtMs,
        'duration_ms': result.durationMs,
        'kind': 'audio',
      });
      ref.invalidate(_callsLogProvider);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Звонок завершён, но журнал не сохранён: $e')),
      );
    }
  }

  static String _contactName(MaxContact c) {
    final name = c.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    final phone = c.phone?.trim();
    if (phone != null && phone.isNotEmpty) return phone;
    return 'Контакт ${c.id}';
  }

  String _formatCallRow(Map<String, Object?> row) {
    final direction = (row['direction'] as String?) ?? 'incoming';
    final missed = (row['missed'] as int? ?? 0) == 1;
    final ts = (row['started_at_ms'] as num?)?.toInt() ?? 0;
    final dur = (row['duration_ms'] as num?)?.toInt() ?? 0;
    final label = missed
        ? 'Пропущенный'
        : direction == 'incoming'
            ? 'Входящий'
            : 'Исходящий';
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final dateStr = DateFormat('d MMM HH:mm', 'ru_RU').format(date);
    final mins = dur ~/ 60000;
    final secs = (dur % 60000) ~/ 1000;
    final durStr = mins > 0
        ? '$mins:${secs.toString().padLeft(2, "0")} мин'
        : (dur > 0 ? '$secs сек' : '');
    return durStr.isEmpty ? '$label · $dateStr' : '$label · $dateStr · $durStr';
  }
}

final _callsLogProvider =
    FutureProvider<List<Map<String, Object?>>>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  await _ensureCallsTable(db);
  return db.raw.query('calls', orderBy: 'started_at_ms DESC', limit: 200);
});

Future<void> _ensureCallsTable(AppDatabase db) async {
  await db.raw.execute('''
    CREATE TABLE IF NOT EXISTS calls (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      peer_id INTEGER NOT NULL,
      peer_name TEXT,
      direction TEXT NOT NULL,
      missed INTEGER NOT NULL DEFAULT 0,
      started_at_ms INTEGER NOT NULL,
      duration_ms INTEGER NOT NULL DEFAULT 0,
      kind TEXT NOT NULL DEFAULT 'audio'
    )
  ''');
}
