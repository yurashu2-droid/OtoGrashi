import 'dart:io';

import '../media/media_presentation_gateway.dart';
import '../media/platform_media_gateway.dart';
import '../storage/asset_repository.dart';
import '../storage/project_database.dart';
import '../storage/project_repository.dart';

final class AppDependencies {
  AppDependencies({
    required this.database,
    required this.media,
    required this.presentation,
    required this.projects,
    required this.assets,
  });

  final ProjectDatabase database;
  final PlatformMediaGateway media;
  final MediaPresentationGateway presentation;
  final ProjectRepository projects;
  final AssetRepository assets;

  static Future<AppDependencies> bootstrap() async {
    final media = PlatformMediaGateway();
    final root = await media.managedRoot();
    final database = await ProjectDatabase.open(Directory(root));
    return AppDependencies(
      database: database,
      media: media,
      presentation: PlatformMediaPresentationGateway(),
      projects: SqliteProjectRepository(database),
      assets: SqliteAssetRepository(
        database,
        inspector: NativeAssetInspector(media),
      ),
    );
  }

  void close() => database.close();
}
