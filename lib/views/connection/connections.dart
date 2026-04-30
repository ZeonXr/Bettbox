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

enum _ConnectionTab { active, closed }

class ConnectionsView extends ConsumerStatefulWidget {
  final bool respectCurrentPage;

  const ConnectionsView({super.key, this.respectCurrentPage = true});

  @override
  ConsumerState<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends ConsumerState<ConnectionsView>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        WindowListener {
  late final TabController _tabController;
  late final ScrollController _activeScrollController;
  late final ScrollController _closedScrollController;
  Timer? _timer;
  ProviderSubscription? _pageLabelSubscription;
  var _currentTab = _ConnectionTab.active;
  var _autoScrollToEnd = false;

  bool get _isForeground {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    return lifecycleState == null ||
        lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    final requests = globalState.appState.requests.list;
    _tabController = TabController(
      length: _ConnectionTab.values.length,
      vsync: this,
    )..addListener(_handleTabChanged);
    _activeScrollController = ScrollController();
    _closedScrollController = ScrollController(
      initialScrollOffset: requests.length * TrackerInfoItem.height,
    );
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
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    globalState.backgroundMode.removeListener(_handleBackgroundModeChanged);
    if (system.isDesktop) {
      windowManager.removeListener(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _activeScrollController.dispose();
    _closedScrollController.dispose();
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
    if (_currentTab != _ConnectionTab.active) {
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
      return;
    }
    final connections = await clashCore.getConnections();
    if (!mounted || !await _shouldRunTimer()) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    ref.read(connectionsProvider.notifier).state = connections;
  }

  void _handleBackgroundModeChanged() {
    unawaited(_syncUpdateTimer());
  }

  void _handleTabChanged() {
    final tab = _ConnectionTab.values[_tabController.index];
    if (tab == _currentTab) {
      return;
    }
    setState(() {
      _currentTab = tab;
    });
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

  Future<void> _scrollActiveConnectionsToTop() async {
    if (!_activeScrollController.hasClients) {
      return;
    }
    await _activeScrollController.animateTo(
      0,
      duration: kTabScrollDuration,
      curve: Curves.easeOut,
    );
  }

  void _onSearch(String value) {
    ref.read(connectionsSearchProvider.notifier).state = value;
  }

  void _onKeywordsUpdate(List<String> keywords) {
    ref.read(connectionsKeywordsProvider.notifier).state = keywords;
  }

  void _toggleAutoScroll() {
    setState(() {
      _autoScrollToEnd = !_autoScrollToEnd;
    });
  }

  void _cancelAutoScroll() {
    if (_autoScrollToEnd) {
      setState(() {
        _autoScrollToEnd = false;
      });
    }
  }

  IconData _getSortIcon(ConnectionsSortType sortType) {
    return switch (sortType) {
      ConnectionsSortType.none => Icons.sort,
      ConnectionsSortType.downloadSpeed => Icons.south_west,
      ConnectionsSortType.uploadSpeed => Icons.north_east,
    };
  }

  String _getSortLabel(ConnectionsSortType sortType) {
    return switch (sortType) {
      ConnectionsSortType.none => appLocalizations.connectionSortDefault,
      ConnectionsSortType.downloadSpeed =>
        appLocalizations.connectionSortDownloadSpeed,
      ConnectionsSortType.uploadSpeed =>
        appLocalizations.connectionSortUploadSpeed,
    };
  }

  Widget _buildSortButton() {
    return Consumer(
      builder: (context, ref, _) {
        final sortType = ref.watch(connectionsSortTypeProvider);
        return CommonPopupBox(
          targetBuilder: (open) {
            return IconButton(
              tooltip: appLocalizations.sort,
              onPressed: () {
                open(offset: const Offset(0, 20));
              },
              icon: Icon(_getSortIcon(sortType)),
            );
          },
          popup: CommonPopupMenu(
            items: [
              for (final item in ConnectionsSortType.values)
                PopupMenuItemData(
                  icon: item == sortType ? Icons.check : _getSortIcon(item),
                  label: _getSortLabel(item),
                  onPressed: () {
                    ref.read(connectionsSortTypeProvider.notifier).state = item;
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    return switch (_currentTab) {
      _ConnectionTab.active => [
        _buildSortButton(),
        IconButton(
          onPressed: _handleCloseAll,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
        IconButton(
          onPressed: _scrollActiveConnectionsToTop,
          icon: const Icon(Icons.vertical_align_top_outlined),
        ),
      ],
      _ConnectionTab.closed => [
        _buildSortButton(),
        IconButton(
          onPressed: () {
            ref.read(requestsProvider.notifier).clearRequests();
          },
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
        IconButton(
          style: _autoScrollToEnd
              ? ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(
                    context.colorScheme.secondaryContainer,
                  ),
                )
              : null,
          onPressed: _toggleAutoScroll,
          icon: const Icon(Icons.vertical_align_top_outlined),
        ),
      ],
    };
  }

  Widget _buildTabBar(BuildContext context) {
    return Material(
      color: context.colorScheme.surface,
      child: TabBar(
        controller: _tabController,
        dividerColor: Colors.transparent,
        indicatorColor: context.colorScheme.primary,
        labelColor: context.colorScheme.primary,
        unselectedLabelColor: context.colorScheme.onSurfaceVariant,
        tabs: [
          Tab(text: appLocalizations.active),
          Tab(text: appLocalizations.closed),
        ],
      ),
    );
  }

  Widget _buildActiveConnections() {
    return Consumer(
      builder: (_, ref, _) {
        final connections = ref.watch(filteredConnectionsProvider);
        final hasConnections = connections.isNotEmpty;

        if (!hasConnections) {
          return NullStatus(
            label: appLocalizations.nullTip(appLocalizations.connection),
          );
        }

        return CommonScrollBar(
          controller: _activeScrollController,
          child: ListView.builder(
            controller: _activeScrollController,
            itemBuilder: (context, index) {
              if (index.isOdd) {
                return const Divider(height: 0);
              }
              final itemIndex = index ~/ 2;
              if (itemIndex >= connections.length) {
                return const SizedBox.shrink();
              }
              final trackerInfo = connections[itemIndex];
              return TrackerInfoItem(
                key: ValueKey(trackerInfo.id),
                trackerInfo: trackerInfo,
                onClickKeyword: (value) {
                  context.commonScaffoldState?.addKeyword(value);
                },
                trailing: IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  style: const ButtonStyle(
                    minimumSize: WidgetStatePropertyAll(Size.zero),
                  ),
                  icon: const Icon(Icons.block),
                  onPressed: () => _handleBlockConnection(trackerInfo.id),
                ),
                detailTitle: appLocalizations.details(
                  appLocalizations.connection,
                ),
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
      },
    );
  }

  Widget _buildClosedConnections() {
    return Consumer(
      builder: (_, ref, _) {
        final connections = ref.watch(filteredClosedConnectionsProvider);
        final hasConnections = connections.isNotEmpty;

        if (!hasConnections) {
          return NullStatus(
            label: appLocalizations.nullTip(appLocalizations.closedConnections),
          );
        }

        return Align(
          alignment: Alignment.topCenter,
          child: CommonScrollBar(
            trackVisibility: false,
            controller: _closedScrollController,
            child: ScrollToEndBox(
              controller: _closedScrollController,
              dataSource: connections,
              enable: _autoScrollToEnd,
              onCancelToEnd: _cancelAutoScroll,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final contentHeight =
                      connections.length * TrackerInfoItem.height;
                  final listViewHeight = contentHeight < constraints.maxHeight
                      ? contentHeight
                      : constraints.maxHeight;

                  return SizedBox(
                    height: listViewHeight,
                    child: ListView.builder(
                      reverse: true,
                      physics: const NextClampingScrollPhysics(),
                      controller: _closedScrollController,
                      itemBuilder: (context, index) {
                        if (index.isOdd) {
                          return const Divider(height: 0);
                        }
                        final itemIndex = index ~/ 2;
                        if (itemIndex >= connections.length) {
                          return const SizedBox.shrink();
                        }
                        final trackerInfo = connections[itemIndex];
                        return TrackerInfoItem(
                          key: ValueKey(trackerInfo.id),
                          trackerInfo: trackerInfo,
                          onClickKeyword: (value) {
                            context.commonScaffoldState?.addKeyword(value);
                          },
                          detailTitle: appLocalizations.details(
                            appLocalizations.closedConnection,
                          ),
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
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: appLocalizations.connections,
      onKeywordsUpdate: _onKeywordsUpdate,
      searchState: AppBarSearchState(onSearch: _onSearch),
      actions: _buildActions(context),
      body: Column(
        children: [
          _buildTabBar(context),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [_buildActiveConnections(), _buildClosedConnections()],
            ),
          ),
        ],
      ),
    );
  }
}
