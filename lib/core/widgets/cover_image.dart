import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Book cover that serves from a local file when one exists (offline
/// downloads) and otherwise falls back to the network image cached by
/// `cached_network_image`.
class CoverImage extends StatelessWidget {
  final String? url;
  final String? localPath;
  final Map<String, String>? httpHeaders;
  final BoxFit fit;
  final double radius;
  final Widget? placeholder;
  final double iconSize;

  const CoverImage({
    super.key,
    this.url,
    this.localPath,
    this.httpHeaders,
    this.fit = BoxFit.cover,
    this.radius = AppColors.cardRadius,
    this.placeholder,
    this.iconSize = 40,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.expand(child: _image()),
    );
  }

  Widget _placeholder() =>
      placeholder ??
      Container(
        color: AppColors.surface,
        child: Center(
          child: Icon(Icons.menu_book_rounded,
              color: AppColors.surfaceElevated, size: iconSize),
        ),
      );

  Widget _image() {
    if (localPath != null) {
      final file = File(localPath!);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: fit,
          errorBuilder: (_, _, _) => _placeholder(),
        );
      }
    }
    if (url == null || url!.isEmpty) return _placeholder();
    return CachedNetworkImage(
      imageUrl: url!,
      httpHeaders: httpHeaders,
      fit: fit,
      placeholder: (_, _) => _placeholder(),
      errorWidget: (_, _, _) => _placeholder(),
    );
  }
}