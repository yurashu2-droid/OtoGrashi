import 'package:flutter/material.dart';

import '../../design/tokens.dart';

/// The 曲 tab: your own songs (the real library), plus 友達 and みんな feeds,
/// which are sample screens until sharing exists. Melody templates live
/// here ("この曲でつくる") rather than in the menu.
final class SongsScreen extends StatefulWidget {
  const SongsScreen({
    required this.mine,
    this.onSettings,
    this.onMakeWithTemplate,
    super.key,
  });

  final Widget mine;
  final VoidCallback? onSettings;
  final VoidCallback? onMakeWithTemplate;

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  static const _segments = ['じぶん', '友達', 'みんな'];
  var _segment = 0;

  void _make() {
    final make = widget.onMakeWithTemplate;
    if (make != null) {
      make();
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('テンプレートからつくるのは、もうすぐ使えます')),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '曲',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: AppTokens.ink,
                    ),
                  ),
                ),
                if (widget.onSettings != null)
                  IconButton(
                    onPressed: widget.onSettings,
                    tooltip: '設定',
                    icon: const Icon(Icons.settings_outlined),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: _Segmented(
              labels: _segments,
              selected: _segment,
              onSelected: (value) => setState(() => _segment = value),
            ),
          ),
          Expanded(
            child: switch (_segment) {
              0 => widget.mine,
              1 => _FriendsFeed(onMake: _make),
              _ => _WorldFeed(onMake: _make),
            },
          ),
        ],
      ),
    ),
  );
}

final class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    height: 44,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: AppTokens.tile,
      borderRadius: BorderRadius.circular(999),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth / labels.length;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 380),
              curve: const Cubic(0.3, 1.45, 0.5, 1),
              left: width * selected,
              top: 0,
              bottom: 0,
              width: width,
              child: Container(
                decoration: BoxDecoration(
                  color: AppTokens.ink,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: i == selected,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelected(i),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                              color: i == selected
                                  ? Colors.white
                                  : AppTokens.mutedInk,
                            ),
                            child: Text(labels[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

final class _Post {
  const _Post(this.who, this.title, this.template, this.tones, this.likes);
  final String who;
  final String title;
  final String template;
  final List<Color> tones;
  final int likes;
}

const _friendPosts = [
  _Post('みお', '沖縄の波でつくった', 'はずむ坂道', [
    Color(0xFF8FCFE0),
    Color(0xFFF6D28B),
    Color(0xFF9ED6B5),
  ], 12),
  _Post('けんた', 'ファミレスのベルでMAD', 'ライラック風', [
    Color(0xFFC9B8F5),
    Color(0xFFF5B3CF),
    Color(0xFFF5DDB3),
  ], 8),
];

const _worldPosts = [
  _Post('saku', '朝の台所だけで1曲', 'しずかな朝', [
    Color(0xFFF5DDB3),
    Color(0xFFB8D8F5),
    Color(0xFFF2B6A6),
  ], 214),
  _Post('nono', '猫の「にゃ」を歌わせた', 'はずむ坂道', [
    Color(0xFFF5B3CF),
    Color(0xFFC9B8F5),
    Color(0xFF9ED6B5),
  ], 1302),
  _Post('toki', '駅の発車ベル合唱', 'ライラック風', [
    Color(0xFFB8D8F5),
    Color(0xFF8FCFE0),
    Color(0xFFF6D28B),
  ], 87),
  _Post('ria', '部活の掛け声ビート', 'まっすぐビート', [
    Color(0xFFF2B6A6),
    Color(0xFFF5DDB3),
    Color(0xFFC9B8F5),
  ], 455),
];

const _templates = [
  ('はずむ坂道', 'よく使われてる'),
  ('ライラック風', 'MADむき'),
  ('しずかな朝', '原声でたのしむ'),
  ('まっすぐビート', 'あつめる'),
];

final class _SampleNote extends StatelessWidget {
  const _SampleNote();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: 12),
    child: Text(
      'サンプル表示です。共有はもうすぐ使えるようになります。',
      style: TextStyle(fontSize: 12, color: AppTokens.mutedInk),
    ),
  );
}

final class _FriendsFeed extends StatelessWidget {
  const _FriendsFeed({required this.onMake});
  final VoidCallback onMake;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    children: [
      const _SampleNote(),
      for (final post in _friendPosts) ...[
        _PostCard(post: post, onMake: onMake, large: true),
        const SizedBox(height: 14),
      ],
    ],
  );
}

final class _WorldFeed extends StatelessWidget {
  const _WorldFeed({required this.onMake});
  final VoidCallback onMake;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    children: [
      const _SampleNote(),
      const Text(
        'いま人気の曲テンプレ',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 92,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _templates.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, i) => GestureDetector(
            onTap: onMake,
            child: Container(
              width: 140,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppTokens.tileRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      for (var k = 0; k < 4; k++)
                        Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: AppTokens.soundColor(i + k),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                  Text(
                    _templates[i].$1,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    _templates[i].$2,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTokens.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 22),
      const Text(
        'みんなの曲',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.56,
        children: [
          for (final post in _worldPosts)
            _PostCard(post: post, onMake: onMake, large: false),
        ],
      ),
    ],
  );
}

final class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.post,
    required this.onMake,
    required this.large,
  });

  final _Post post;
  final VoidCallback onMake;
  final bool large;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: post.tones.first,
              child: Text(
                post.who.characters.first,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppTokens.ink,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                post.who,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Icon(
              Icons.favorite_rounded,
              size: 14,
              color: AppTokens.blush,
            ),
            const SizedBox(width: 3),
            Text(
              '${post.likes}',
              style: const TextStyle(
                fontSize: 11,
                color: AppTokens.mutedInk,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: large ? 4 / 3 : 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Row(
              children: [
                for (final tone in post.tones)
                  Expanded(child: Container(color: tone)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          post.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppTokens.tile,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '♪ ${post.template}',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
        if (large) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            width: double.infinity,
            child: FilledButton(
              onPressed: onMake,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
              ),
              child: const Text('この曲で、自分の音でつくる'),
            ),
          ),
        ] else ...[
          const Spacer(),
          GestureDetector(
            onTap: onMake,
            child: const Text(
              'この曲でつくる →',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppTokens.ink,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
