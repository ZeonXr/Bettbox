import 'dart:typed_data';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/providers/config.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final _iconCache = <String, Uint8List?>{};
final _iconCacheKeys = <String>[];
const _maxIconCacheSize = 50;
const double _chainLabelSpacing = 6;
Uint8List? _defaultIconCache;
Future<Uint8List?>? _defaultIconFuture;

void _addToIconCache(String key, Uint8List? value) {
  if (_iconCache.containsKey(key)) {
    _iconCacheKeys.remove(key);
    _iconCacheKeys.add(key);
    _iconCache[key] = value;
    return;
  }

  while (_iconCacheKeys.length >= _maxIconCacheSize) {
    final oldestKey = _iconCacheKeys.removeAt(0);
    _iconCache.remove(oldestKey);
  }

  _iconCacheKeys.add(key);
  _iconCache[key] = value;
}

List<String> _getDisplayChains(List<String> chains) {
  return chains.reversed.toList();
}

TrackerInfo? _findTrackerInfoById(List<TrackerInfo> connections, String id) {
  for (final item in connections) {
    if (item.id == id) {
      return item;
    }
  }
  return null;
}

class _ConnectionSpeedStatus extends StatefulWidget {
  final TrackerInfo trackerInfo;

  const _ConnectionSpeedStatus({required this.trackerInfo});

  static const double width = 78;

  @override
  State<_ConnectionSpeedStatus> createState() => _ConnectionSpeedStatusState();
}

class _ConnectionSpeedStatusState extends State<_ConnectionSpeedStatus>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    final curvedAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    _opacity = Tween<double>(begin: 0.55, end: 1).animate(curvedAnimation);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _getHighlightColor(BuildContext context, Color baseColor) {
    final brightness = Theme.of(context).brightness;
    return Color.lerp(
      baseColor,
      Colors.white,
      brightness == Brightness.dark ? 0.28 : 0.12,
    )!;
  }

  @override
  Widget build(BuildContext context) {
    final uploadColor = _getHighlightColor(
      context,
      context.colorScheme.primary,
    );
    final downloadColor = _getHighlightColor(
      context,
      context.colorScheme.tertiary,
    );
    final textStyle = context.textTheme.labelSmall?.copyWith(
      color: context.colorScheme.onSurfaceVariant,
      height: 1.15,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return SizedBox(
      width: _ConnectionSpeedStatus.width,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.55,
          ),
          border: Border.all(color: context.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, _) {
            final disableAnimations =
                MediaQuery.maybeOf(context)?.disableAnimations ?? false;
            final opacity = disableAnimations ? 1.0 : _opacity.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SpeedRow(
                  icon: Icons.arrow_upward_rounded,
                  iconColor: uploadColor,
                  opacity: opacity,
                  value: TrafficValue(
                    value: widget.trackerInfo.uploadSpeed,
                  ).speedShow,
                  textStyle: textStyle,
                ),
                _SpeedRow(
                  icon: Icons.arrow_downward_rounded,
                  iconColor: downloadColor,
                  opacity: opacity,
                  value: TrafficValue(
                    value: widget.trackerInfo.downloadSpeed,
                  ).speedShow,
                  textStyle: textStyle,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SpeedRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final double opacity;
  final String value;
  final TextStyle? textStyle;

  const _SpeedRow({
    required this.icon,
    required this.iconColor,
    required this.opacity,
    required this.value,
    required this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 12,
          child: Icon(
            icon,
            size: 14,
            color: iconColor.withValues(alpha: opacity),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 1,
            softWrap: false,
            style: textStyle,
          ),
        ),
      ],
    );
  }
}

class TrackerInfoItem extends ConsumerWidget {
  final TrackerInfo trackerInfo;
  final bool isActive;
  final Function(String)? onClickKeyword;
  final Future<void> Function(String id)? onCloseConnection;
  final Widget? trailing;
  final String detailTitle;

  const TrackerInfoItem({
    super.key,
    required this.trackerInfo,
    this.isActive = false,
    this.onClickKeyword,
    this.onCloseConnection,
    this.trailing,
    required this.detailTitle,
  });

  static double get subTitleHeight {
    return globalState.measure.bodySmallHeight + 20;
  }

  static double get height {
    final measure = globalState.measure;
    return measure.bodyMediumHeight +
        8 +
        8 +
        measure.bodyLargeHeight +
        subTitleHeight +
        12 * 2;
  }

  String _getSourceText(TrackerInfo trackerInfo) {
    final progress = trackerInfo.progressText.isNotEmpty
        ? '${trackerInfo.progressText} · '
        : '';
    final traffic = Traffic(up: trackerInfo.upload, down: trackerInfo.download);
    return '$progress${traffic.toTransferText()}';
  }

  List<String> _getVisibleChains(List<String> chains) {
    final displayChains = _getDisplayChains(chains);
    if (displayChains.length <= 2) {
      return displayChains;
    }
    return [displayChains.first, displayChains.last];
  }

  @override
  Widget build(BuildContext context, ref) {
    final value = ref.watch(
      patchClashConfigProvider.select(
        (state) =>
            state.findProcessMode == FindProcessMode.always && system.isAndroid,
      ),
    );
    final visibleChains = _getVisibleChains(trackerInfo.chains);
    final chainLabels = [
      if (trackerInfo.ruleText.isNotEmpty) trackerInfo.ruleText,
      ...visibleChains,
    ];
    final trailingWidgets = [
      if (isActive) _ConnectionSpeedStatus(trackerInfo: trackerInfo),
      ?trailing,
    ];
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          spacing: 8,
          children: [
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      trackerInfo.desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              trackerInfo.start.lastUpdateTimeDesc,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colorScheme.onSurface.opacity60,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _getSourceText(trackerInfo),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final subTitle = SizedBox(
      height: subTitleHeight,
      child: Row(
        // spacing: 6,
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: ListView.separated(
              separatorBuilder: (_, _) => SizedBox(width: _chainLabelSpacing),
              padding: EdgeInsets.zero,
              scrollDirection: Axis.horizontal,
              itemCount: chainLabels.length,
              itemBuilder: (_, index) {
                final chain = chainLabels[index];
                return CommonChip(
                  label: chain,
                  labelStyle: context.textTheme.bodySmall?.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () {
                    if (onClickKeyword == null) return;
                    onClickKeyword!(chain);
                  },
                );
              },
            ),
          ),
          if (trailingWidgets.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: _chainLabelSpacing,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: trailingWidgets,
              ),
            ),
        ],
      ),
    );
    final icon = value
        ? _ProcessIcon(
            process: trackerInfo.metadata.process,
            onClick: onClickKeyword,
          )
        : null;
    return RepaintBoundary(
      child: ListItem(
        onTap: () {
          showExtend(
            context,
            builder: (_, type) {
              return Consumer(
                builder: (_, ref, _) {
                  final activeTrackerInfo = ref.watch(
                    connectionsProvider.select(
                      (connections) =>
                          _findTrackerInfoById(connections, trackerInfo.id),
                    ),
                  );
                  final isActive = activeTrackerInfo != null;
                  return AdaptiveSheetScaffold(
                    type: type,
                    body: TrackerInfoDetailView(trackerInfo: trackerInfo),
                    title: detailTitle,
                    titleStatus: activeTrackerInfo != null
                        ? _ConnectionSpeedStatus(trackerInfo: activeTrackerInfo)
                        : null,
                    actions: [
                      if (isActive && onCloseConnection != null)
                        IconButton(
                          icon: const Icon(Icons.block),
                          onPressed: () {
                            onCloseConnection!(trackerInfo.id);
                          },
                        ),
                      if (type == SheetType.sideSheet) const CloseButton(),
                    ],
                  );
                },
              );
            },
          );
        },
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 12,
              children: [
                ?icon,
                Flexible(child: title),
              ],
            ),
            const SizedBox(height: 8),
            subTitle,
          ],
        ),
      ),
    );
  }
}

Future<Uint8List?> _getPackageIcon(String process) async {
  if (process.isEmpty) {
    return _getDefaultPackageIcon();
  }
  final cachedIcon = _iconCache[process];
  if (cachedIcon != null) {
    return cachedIcon;
  }
  final icon = await app.getPackageIcon(process);
  if (icon != null) {
    _addToIconCache(process, icon);
    return icon;
  }
  return _getDefaultPackageIcon();
}

Future<Uint8List?> _getDefaultPackageIcon() {
  final cachedIcon = _defaultIconCache;
  if (cachedIcon != null) {
    return Future.value(cachedIcon);
  }
  return _defaultIconFuture ??= app.getPackageIcon('').then((icon) {
    if (icon != null) {
      _defaultIconCache = icon;
    }
    _defaultIconFuture = null;
    return icon;
  });
}

class _ProcessIcon extends StatefulWidget {
  final String process;
  final Function(String)? onClick;

  const _ProcessIcon({required this.process, this.onClick});

  @override
  State<_ProcessIcon> createState() => _ProcessIconState();
}

class _ProcessIconState extends State<_ProcessIcon> {
  late Future<Uint8List?> _iconFuture;

  @override
  void initState() {
    super.initState();
    _iconFuture = _getPackageIcon(widget.process);
  }

  @override
  void didUpdateWidget(_ProcessIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.process != widget.process) {
      _iconFuture = _getPackageIcon(widget.process);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheSize = (42 * devicePixelRatio).ceil();

    return RepaintBoundary(
      child: GestureDetector(
        onTap: () {
          if (widget.process.isEmpty) return;
          widget.onClick?.call(widget.process);
        },
        child: Container(
          margin: const EdgeInsets.only(top: 4),
          width: 42,
          height: 42,
          alignment: Alignment.center,
          child: FutureBuilder<Uint8List?>(
            future: _iconFuture,
            builder: (context, snapshot) {
              final iconBytes = snapshot.data;
              if (iconBytes == null) {
                return const SizedBox(width: 42, height: 42);
              }
              return Image(
                image: ResizeImage(
                  MemoryImage(iconBytes),
                  width: cacheSize,
                  height: cacheSize,
                  allowUpscaling: false,
                ),
                width: 42,
                height: 42,
                gaplessPlayback: true,
              );
            },
          ),
        ),
      ),
    );
  }
}

class TrackerInfoDetailView extends ConsumerStatefulWidget {
  final TrackerInfo trackerInfo;

  const TrackerInfoDetailView({super.key, required this.trackerInfo});

  @override
  ConsumerState<TrackerInfoDetailView> createState() =>
      _TrackerInfoDetailViewState();
}

class _TrackerInfoDetailViewState extends ConsumerState<TrackerInfoDetailView> {
  late TrackerInfo _lastTrackerInfo;

  @override
  void initState() {
    super.initState();
    _lastTrackerInfo = widget.trackerInfo;
  }

  String _getRuleText(TrackerInfo trackerInfo) {
    return trackerInfo.ruleText;
  }

  String _getProgressText(TrackerInfo trackerInfo) {
    final process = trackerInfo.metadata.process;
    final uid = trackerInfo.metadata.uid;
    if (uid != 0) {
      return '$process($uid)';
    }
    return process;
  }

  String _getSourceText(TrackerInfo trackerInfo) {
    final sourceIP = trackerInfo.metadata.sourceIP;
    if (sourceIP.isEmpty) {
      return '';
    }
    final sourcePort = trackerInfo.metadata.sourcePort;
    if (sourcePort.isNotEmpty) {
      return '$sourceIP:$sourcePort';
    }
    return sourceIP;
  }

  String _getDestinationText(TrackerInfo trackerInfo) {
    final destinationIP = trackerInfo.metadata.destinationIP;
    if (destinationIP.isEmpty) {
      return '';
    }
    final destinationPort = trackerInfo.metadata.destinationPort;
    if (destinationPort.isNotEmpty) {
      return '$destinationIP:$destinationPort';
    }
    return destinationIP;
  }

  Widget _buildChains(TrackerInfo trackerInfo) {
    final displayChains = _getDisplayChains(trackerInfo.chains);
    final chains = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        for (final chain in displayChains)
          CommonChip(label: chain, onPressed: () {}),
      ],
    );
    return ListItem(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appLocalizations.proxyChains),
          Flexible(child: chains),
        ],
      ),
    );
  }

  Widget _buildItem({
    required String title,
    required String desc,
    bool quickCopy = false,
  }) {
    return ListItem(
      title: Row(
        spacing: 16,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            spacing: 4,
            children: [
              Text(title),
              if (quickCopy)
                Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.content_copy, size: 18),
                    onPressed: () {},
                  ),
                ),
            ],
          ),
          Flexible(child: Text(desc, textAlign: TextAlign.end)),
        ],
      ),
    );
  }

  TrackerInfo _getCurrentTrackerInfo() {
    final activeTrackerInfo = ref.watch(
      connectionsProvider.select(
        (connections) =>
            _findTrackerInfoById(connections, widget.trackerInfo.id),
      ),
    );
    if (activeTrackerInfo != null) {
      _lastTrackerInfo = activeTrackerInfo;
    }
    return _lastTrackerInfo;
  }

  @override
  Widget build(BuildContext context) {
    final currentTrackerInfo = _getCurrentTrackerInfo();
    final progressText = _getProgressText(currentTrackerInfo);
    final sourceText = _getSourceText(currentTrackerInfo);
    final destinationText = _getDestinationText(currentTrackerInfo);
    final items = [
      _buildItem(
        title: appLocalizations.creationTime,
        desc: currentTrackerInfo.start.showFull,
      ),
      if (progressText.isNotEmpty)
        _buildItem(title: appLocalizations.progress, desc: progressText),
      _buildItem(
        title: appLocalizations.networkType,
        desc: currentTrackerInfo.metadata.network,
      ),
      _buildItem(
        title: appLocalizations.rule,
        desc: _getRuleText(currentTrackerInfo),
      ),
      if (currentTrackerInfo.metadata.host.isNotEmpty)
        _buildItem(
          title: appLocalizations.host,
          desc: currentTrackerInfo.metadata.host,
        ),
      if (sourceText.isNotEmpty)
        _buildItem(title: appLocalizations.source, desc: sourceText),
      if (destinationText.isNotEmpty)
        _buildItem(title: appLocalizations.destination, desc: destinationText),
      _buildItem(
        title: appLocalizations.uploadAmount,
        desc: TrafficValue(value: currentTrackerInfo.upload).show,
      ),
      _buildItem(
        title: appLocalizations.downloadAmount,
        desc: TrafficValue(value: currentTrackerInfo.download).show,
      ),
      if (currentTrackerInfo.metadata.destinationGeoIP.isNotEmpty)
        _buildItem(
          title: appLocalizations.destinationGeoIP,
          desc: currentTrackerInfo.metadata.destinationGeoIP.join(' '),
        ),
      if (currentTrackerInfo.metadata.destinationIPASN.isNotEmpty)
        _buildItem(
          title: appLocalizations.destinationIPASN,
          desc: currentTrackerInfo.metadata.destinationIPASN,
        ),
      if (currentTrackerInfo.metadata.dnsMode != null)
        _buildItem(
          title: appLocalizations.dnsMode,
          desc: currentTrackerInfo.metadata.dnsMode!.name,
        ),
      if (currentTrackerInfo.metadata.specialProxy.isNotEmpty)
        _buildItem(
          title: appLocalizations.specialProxy,
          desc: currentTrackerInfo.metadata.specialProxy,
        ),
      if (currentTrackerInfo.metadata.specialRules.isNotEmpty)
        _buildItem(
          title: appLocalizations.specialRules,
          desc: currentTrackerInfo.metadata.specialRules,
        ),
      if (currentTrackerInfo.metadata.remoteDestination.isNotEmpty)
        _buildItem(
          title: appLocalizations.remoteDestination,
          desc: currentTrackerInfo.metadata.remoteDestination,
        ),
      _buildChains(currentTrackerInfo),
    ];
    return SelectionArea(
      child: ListView.builder(
        padding: EdgeInsets.symmetric(vertical: 12),
        itemCount: items.length,
        itemBuilder: (_, index) {
          return items[index];
        },
      ),
    );
  }
}
