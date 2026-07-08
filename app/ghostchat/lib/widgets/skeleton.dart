// Skeleton-заглушки вместо спиннеров на начальной загрузке контента
// (список чатов, лента). Дешёвая pulse-анимация цвета (без ShaderMask/shimmer
// градиента) — работает ровно на слабых телефонах.
import 'package:flutter/material.dart';
import '../theme.dart';

class SkeletonBox extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const SkeletonBox({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.radius = 6,
  });

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final color = Color.lerp(
          GE.surface,
          GE.surface.withValues(alpha: 0.35),
          _c.value,
        )!;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}

// Ряд-заглушка под _DialogTile (avatar 48 + имя/время + превью).
class SkeletonDialogTile extends StatelessWidget {
  const SkeletonDialogTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          const SkeletonBox(width: 48, height: 48, radius: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SkeletonBox(width: 120, height: 14),
                    const Spacer(),
                    const SkeletonBox(width: 30, height: 11),
                  ],
                ),
                const SizedBox(height: 8),
                const SkeletonBox(width: 190, height: 13),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Список заглушек-диалогов (вместо спиннера при первой загрузке ChatListScreen).
class SkeletonDialogList extends StatelessWidget {
  final int count;
  const SkeletonDialogList({super.key, this.count = 7});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (_, _) => const SkeletonDialogTile(),
    );
  }
}

// Карточка-заглушка под _PostCard (шапка avatar 38 + имя/время, затем текст
// и медиа-блок).
class SkeletonFeedCard extends StatelessWidget {
  const SkeletonFeedCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: GE.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(GE.radiusMd),
        border: Border.all(color: GE.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SkeletonBox(width: 38, height: 38, radius: 19),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SkeletonBox(width: 110, height: 13),
                    const SizedBox(height: 6),
                    const SkeletonBox(width: 70, height: 11),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const SkeletonBox(width: double.infinity, height: 13),
          const SizedBox(height: 6),
          const SkeletonBox(width: 220, height: 13),
          const SizedBox(height: 10),
          const SkeletonBox(width: double.infinity, height: 160, radius: 12),
        ],
      ),
    );
  }
}

// Список заглушек-постов (вместо спиннера при первой загрузке ленты).
class SkeletonFeedList extends StatelessWidget {
  final int count;
  const SkeletonFeedList({super.key, this.count = 3});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, _) => const SkeletonFeedCard(),
    );
  }
}

// Универсальный ряд avatar+2 строки — под уведомления/комментарии/поиск/
// настройки, где карточка проще чем полноценный SkeletonDialogTile.
class SkeletonRow extends StatelessWidget {
  final double avatarSize;
  const SkeletonRow({super.key, this.avatarSize = 36});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SkeletonBox(
            width: avatarSize,
            height: avatarSize,
            radius: avatarSize / 2,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonBox(width: 160, height: 13),
                const SizedBox(height: 7),
                const SkeletonBox(width: 100, height: 11),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SkeletonRowList extends StatelessWidget {
  final int count;
  final double avatarSize;
  const SkeletonRowList({super.key, this.count = 6, this.avatarSize = 36});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      itemBuilder: (_, _) => SkeletonRow(avatarSize: avatarSize),
    );
  }
}

// Карточка-плитка для сеток (NFT/минисочки): картинка + подпись.
class SkeletonTile extends StatelessWidget {
  const SkeletonTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Expanded(child: SkeletonBox(height: double.infinity, radius: 12)),
        const SizedBox(height: 6),
        const SkeletonBox(width: 90, height: 12),
      ],
    );
  }
}

class SkeletonGrid extends StatelessWidget {
  final int count;
  final int crossAxisCount;
  final double childAspectRatio;
  const SkeletonGrid({
    super.key,
    this.count = 6,
    this.crossAxisCount = 2,
    this.childAspectRatio = 0.75,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: childAspectRatio,
      ),
      itemCount: count,
      itemBuilder: (_, _) => const SkeletonTile(),
    );
  }
}

// Карточка с 2 строками текста без аватара (заметки, короткие списки).
class SkeletonTextCard extends StatelessWidget {
  const SkeletonTextCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: GE.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(GE.radiusMd),
        border: Border.all(color: GE.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          SkeletonBox(width: double.infinity, height: 13),
          SizedBox(height: 7),
          SkeletonBox(width: 140, height: 11),
        ],
      ),
    );
  }
}

class SkeletonTextCardList extends StatelessWidget {
  final int count;
  const SkeletonTextCardList({super.key, this.count = 5});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      itemBuilder: (_, _) => const SkeletonTextCard(),
    );
  }
}

// Шапка профиля: аватар + имя + био + строка статов.
class SkeletonProfileHeader extends StatelessWidget {
  const SkeletonProfileHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const SkeletonBox(width: 84, height: 84, radius: 42),
          const SizedBox(height: 14),
          const SkeletonBox(width: 140, height: 16),
          const SizedBox(height: 8),
          const SkeletonBox(width: 200, height: 12),
          const SizedBox(height: 16),
          Row(
            children: const [
              Expanded(child: SkeletonBox(height: 54, radius: 12)),
              SizedBox(width: 10),
              Expanded(child: SkeletonBox(height: 54, radius: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
