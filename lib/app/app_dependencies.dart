import 'dart:io';

import '../media/media_presentation_gateway.dart';
import '../media/platform_media_gateway.dart';
import '../storage/asset_repository.dart';
import '../storage/profile_store.dart';
import '../storage/project_database.dart';
import '../storage/project_repository.dart';

final class AppDependencies {
  AppDependencies({
    required this.database,
    required this.media,
    required this.presentation,
    required this.projects,
    required this.assets,
    this.profile,
  });

  final ProjectDatabase database;
  final PlatformMediaGateway media;
  final MediaPresentationGateway presentation;
  final ProjectRepository projects;
  final AssetRepository assets;
  final ProfileStore? profile;

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
      profile: ProfileStore(File('$root/owner_name.txt')),
    );
  }

  void close() => database.close();
}
