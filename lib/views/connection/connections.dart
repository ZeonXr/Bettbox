import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'item.dart';

class _ConnectionTrafficSample {
  final int upload;
  final int download;
  final DateTime time;

  const _ConnectionTrafficSample({
    required this.upload,
    required this.download,
    required this.time,
  });
}

class ConnectionsView extends ConsumerStatefulWidget {
  final bool respectCurrentPage;

  const ConnectionsView({super.key, this.respectCurrentPage = true});

  @override
  ConsumerState<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends ConsumerState<ConnectionsView>
    with WidgetsBindingObserver, WindowListener {
  late final ScrollController _scrollController;
  Timer? _timer;
  ProviderSubscription? _pageLabelSubscription;
  Map<String, _ConnectionTrafficSample> _connectionTrafficSamples = {};

  static const _closedHistoryLimit = 256;

  bool get _isForeground {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    return lifecycleState == null ||
        lifecycleState == AppLifecycleState.resumed ||
        lifecycleState == AppLifecycleState.inactive;
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addObserver(this);
    globalState.backgroundMode.addListener(_handleBackgroundModeChanged);
    if (system.isDesktop) {
      windowManager.addListener(this);
    }
    _pageLabelSubscription = ref.listenManual(currentPageLabelProvider, (
      prev,
      next,
    ) {
      if (prev != next) {
        unawaited(_syncUpdateTimer());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_syncUpdateTimer());
    });
  }

  @override
  void dispose() {
    _pageLabelSubscription?.close();
    globalState.backgroundMode.removeListener(_handleBackgroundModeChanged);
    if (system.isDesktop) {
      windowManager.removeListener(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<bool> _shouldRunTimer() async {
    if (!mounted) return false;
    if (globalState.backgroundMode.value) {
      return false;
    }
    if (widget.respectCurrentPage &&
        ref.read(currentPageLabelProvider) != PageLabel.connections) {
      return false;
    }
    if (!_isForeground) {
      return false;
    }
    if (system.isDesktop && await window?.isVisible == false) {
      return false;
    }
    return true;
  }

  Future<void> _syncUpdateTimer() async {
    final shouldRun = await _shouldRunTimer();
    if (!mounted) return;
    if (!shouldRun) {
      _timer?.cancel();
      _timer = null;
      _connectionTrafficSamples = {};
      return;
    }
    if (_timer != null) {
      return;
    }
    await _updateConnections();
    if (!mounted || !await _shouldRunTimer()) {
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_updateConnections());
    });
  }

  Future<void> _updateConnections() async {
    if (!mounted || !await _shouldRunTimer()) {
      _timer?.cancel();
      _timer = null;
      _connectionTrafficSamples = {};
      return;
    }
    final connections = await clashCore.getConnections();
    if (!mounted || !await _shouldRunTimer()) {
      _timer?.cancel();
      _timer = null;
      _connectionTrafficSamples = {};
      return;
    }
    _applyConnections(connections);
  }

  int _calculateConnectionSpeed({
    required int currentValue,
    required int previousValue,
    required Duration elapsed,
  }) {
    final elapsedMilliseconds = elapsed.inMilliseconds;
    if (elapsedMilliseconds <= 0) {
      return 0;
    }
    final delta = currentValue - previousValue;
    if (delta <= 0) {
      return 0;
    }
    return (delta * 1000 / elapsedMilliseconds).round();
  }

  List<TrackerInfo> _applyConnectionSpeeds(List<TrackerInfo> connections) {
    final now = DateTime.now();
    final previousSamples = _connectionTrafficSamples;
    final nextSamples = <String, _ConnectionTrafficSample>{};
    final nextConnections = [
      for (final item in connections)
        () {
          final previousSample = previousSamples[item.id];
          final nextSample = _ConnectionTrafficSample(
            upload: item.upload,
            download: item.download,
            time: now,
          );
          nextSamples[item.id] = nextSample;
          if (previousSample == null) {
            return item.copyWith(uploadSpeed: 0, downloadSpeed: 0);
          }
          final elapsed = now.difference(previousSample.time);
          return item.copyWith(
            uploadSpeed: _calculateConnectionSpeed(
              currentValue: item.upload,
              previousValue: previousSample.upload,
              elapsed: elapsed,
            ),
            downloadSpeed: _calculateConnectionSpeed(
              currentValue: item.download,
              previousValue: previousSample.download,
              elapsed: elapsed,
            ),
          );
        }(),
    ];
    _connectionTrafficSamples = nextSamples;
    return nextConnections;
  }

  void _applyConnections(List<TrackerInfo> connections) {
    final activeConnections = _applyConnectionSpeeds(connections);
    final previousConnections = ref.read(connectionsProvider);
    final history = ref.read(connectionHistoryProvider);
    final closedConnections = ref.read(closedConnectionsProvider);
    final activeIds = activeConnections.map((item) => item.id).toSet();
    final historyIds = history.map((item) => item.id).toSet();
    final nextClosedMap = <String, TrackerInfo>{
      for (final item in closedConnections) item.id: item,
    };

    for (final item in previousConnections) {
      if (!activeIds.contains(item.id) && historyIds.contains(item.id)) {
        nextClosedMap[item.id] = item.copyWith(
          uploadSpeed: 0,
          downloadSpeed: 0,
        );
      }
    }

    final nextHistoryMap = <String, TrackerInfo>{
      for (final item in history) item.id: item,
      for (final item in activeConnections) item.id: item,
    };
    final nextClosed = nextClosedMap.values
        .where((item) => !activeIds.contains(item.id))
        .toList()
        .takeLast(count: _closedHistoryLimit)
        .toList();

    ref.read(connectionsProvider.notifier).state = activeConnections;
    ref.read(connectionHistoryProvider.notifier).state = nextHistoryMap.values
        .toList()
        .takeLast(count: _closedHistoryLimit)
        .toList();
    ref.read(closedConnectionsProvider.notifier).state = nextClosed;
  }

  void _handleBackgroundModeChanged() {
    unawaited(_syncUpdateTimer());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_syncUpdateTimer());
  }

  @override
  void onWindowMinimize() {
    unawaited(_syncUpdateTimer());
  }

  @override
  void onWindowRestore() {
    unawaited(_syncUpdateTimer());
  }

  Future<void> _handleBlockConnection(String id) async {
    clashCore.closeConnection(id);
    await _updateConnections();
  }

  void _handleCloseAll() async {
    clashCore.closeConnections();
    await _updateConnections();
  }

  void _handleClearHistory() async {
    clashCore.closeConnections();
    await _updateConnections();
    ref.read(requestsProvider.notifier).clearRequests();
    ref.read(closedConnectionsProvider.notifier).state = [];
    ref.read(connectionHistoryProvider.notifier).state = [];
  }

  void _handlePrimaryAction() {
    final tab = ref.read(connectionsTabProvider);
    switch (tab) {
      case ConnectionsTab.active:
        _handleCloseAll();
      case ConnectionsTab.all:
        _handleClearHistory();
    }
  }

  void _onSearch(String value) {
    ref.read(connectionsSearchProvider.notifier).state = value;
  }

  void _onKeywordsUpdate(List<String> keywords) {
    ref.read(connectionsKeywordsProvider.notifier).state = keywords;
  }

  String _getTabLabel(ConnectionsTab tab) {
    return switch (tab) {
      ConnectionsTab.all => appLocalizations.all,
      ConnectionsTab.active => appLocalizations.activeConnections,
    };
  }

  Widget _buildTabSelector(BuildContext context, {required bool isMobile}) {
    final tab = ref.watch(connectionsTabProvider);
    final allCount = ref.watch(
      filteredAllConnectionsProvider.select((state) => state.length),
    );
    final activeCount = ref.watch(
      filteredActiveConnectionsProvider.select((state) => state.length),
    );
    final counts = {
      ConnectionsTab.all: allCount,
      ConnectionsTab.active: activeCount,
    };
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: isMobile ? double.infinity : null,
        child: CommonTabBar<ConnectionsTab>(
          children: {
            for (final item in ConnectionsTab.values)
              item: _ConnectionTabContent(
                label: _getTabLabel(item),
                count: counts[item] ?? 0,
                selected: tab == item,
              ),
          },
          groupValue: tab,
          onValueChanged: (value) {
            if (value == null || tab == value) {
              return;
            }
            ref.read(connectionsTabProvider.notifier).state = value;
          },
          thumbColor: Color.alphaBlend(
            context.colorScheme.primary.withValues(alpha: 0.12),
            context.colorScheme.surface,
          ),
          backgroundColor: context.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.all(4),
          proportionalWidth: isMobile,
        ),
      ),
    );
  }

  Widget _buildSortButton() {
    final sortType = ref.watch(connectionsSortProvider);

    return PopupMenuButton<ConnectionsSortType>(
      tooltip: appLocalizations.defaultSort,
      icon: Icon(_getSortIcon(sortType)),
      onSelected: (value) {
        ref.read(connectionsSortProvider.notifier).state = value;
      },
      itemBuilder: (context) {
        return ConnectionsSortType.values.map((type) {
          final isSelected = type == sortType;
          return PopupMenuItem<ConnectionsSortType>(
            value: type,
            child: Row(
              children: [
                Icon(_getSortIcon(type), size: 20),
                const SizedBox(width: 12),
                Text(_getSortLabel(type)),
                if (isSelected) ...[
                  const Spacer(),
                  Icon(Icons.check,
                      size: 18, color: context.colorScheme.primary),
                ],
              ],
            ),
          );
        }).toList();
      },
    );
  }

  IconData _getSortIcon(ConnectionsSortType type) {
    return switch (type) {
      ConnectionsSortType.none => Icons.sort,
      ConnectionsSortType.trafficSpeed => Icons.speed,
      ConnectionsSortType.totalTraffic => Icons.swap_vert,
      ConnectionsSortType.time => Icons.access_time,
    };
  }

  String _getSortLabel(ConnectionsSortType type) {
    return switch (type) {
      ConnectionsSortType.none => appLocalizations.defaultSort,
      ConnectionsSortType.trafficSpeed => appLocalizations.speedSort,
      ConnectionsSortType.totalTraffic => appLocalizations.totalSort,
      ConnectionsSortType.time => appLocalizations.timeSort,
    };
  }

  Widget _buildConnectionHeader(BuildContext context) {
    final isMobile = ref.watch(isMobileViewProvider);
    final scaffoldState = context.commonScaffoldState;
    final hasKeywords = scaffoldState != null;

    return Material(
      color: context.colorScheme.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = isMobile || constraints.maxWidth < 500;
          final keywords = scaffoldState?.buildKeywords(
            padding: EdgeInsets.zero,
            alignment: isNarrow ? WrapAlignment.start : WrapAlignment.end,
          );

          final tabSelector = _buildTabSelector(context, isMobile: isNarrow);

          return Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, isNarrow ? 0 : 4),
            child: isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      tabSelector,
                      if (hasKeywords) ...[
                        const SizedBox(height: 8),
                        keywords!,
                      ],
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      tabSelector,
                      if (hasKeywords) ...[
                        const SizedBox(width: 8),
                        Expanded(child: keywords!),
                      ],
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _buildConnectionsList(
    List<TrackerInfo> connections,
    ConnectionsTab tab,
  ) {
    if (connections.isEmpty) {
      return NullStatus(label: appLocalizations.nullTip(_getTabLabel(tab)));
    }

    return CommonScrollBar(
      controller: _scrollController,
      child: ListView.builder(
        controller: _scrollController,
        itemBuilder: (context, index) {
          if (index.isOdd) {
            return const Divider(height: 0);
          }
          final itemIndex = index ~/ 2;
          if (itemIndex >= connections.length) {
            return const SizedBox.shrink();
          }
          final trackerInfo = connections[itemIndex];
          final isActive = ref
              .read(connectionsProvider)
              .any((item) => item.id == trackerInfo.id);
          return TrackerInfoItem(
            key: ValueKey('${tab.name}_${trackerInfo.id}'),
            trackerInfo: trackerInfo,
            isActive: isActive,
            onClickKeyword: (value) {
              context.commonScaffoldState?.addKeyword(value);
            },
            onCloseConnection: _handleBlockConnection,
            trailing: isActive
                ? IconButton(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    style: const ButtonStyle(
                      minimumSize: WidgetStatePropertyAll(Size.zero),
                    ),
                    icon: const Icon(Icons.block),
                    onPressed: () => _handleBlockConnection(trackerInfo.id),
                  )
                : null,
            detailTitle: appLocalizations.connectionDetails,
          );
        },
        itemExtentBuilder: (index, _) {
          if (index.isOdd) {
            return 0;
          }
          return TrackerInfoItem.height;
        },
        itemCount: connections.length * 2 - 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: appLocalizations.connections,
      onKeywordsUpdate: _onKeywordsUpdate,
      searchState: AppBarSearchState(onSearch: _onSearch),
      showKeywords: false,
      singleKeyword: true,
      actions: [
        _buildSortButton(),
        IconButton(
          onPressed: _handlePrimaryAction,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ],
      body: Column(
        children: [
          Builder(builder: _buildConnectionHeader),
          Expanded(
            child: Consumer(
              builder: (_, ref, _) {
                final tab = ref.watch(connectionsTabProvider);
                final connections = ref.watch(filteredConnectionsProvider);
                return _buildConnectionsList(connections, tab);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionTabContent extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;

  const _ConnectionTabContent({
    required this.label,
    required this.count,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final contentColor = selected
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.labelLarge?.copyWith(
                color: contentColor,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 32,
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.labelLarge?.copyWith(
                color: contentColor,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
