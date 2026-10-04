import 'dart:io';

import '../media/media_presentation_gateway.dart';
import '../media/platform_media_gateway.dart';
import '../storage/asset_repository.dart';
import '../storage/folder_repository.dart';
import '../storage/profile_store.dart';
import '../storage/project_database.dart';
import '../storage/project_repository.dart';
import '../sharing/shared_folder_service.dart';

final class AppDependencies {
  AppDependencies({
    required this.database,
    required this.media,
    required this.presentation,
    required this.projects,
    required this.assets,
    this.profile,
    this.folders,
    this.sharedFolders,
  });

  final ProjectDatabase database;
  final PlatformMediaGateway media;
  final MediaPresentationGateway presentation;
  final ProjectRepository projects;
  final AssetRepository assets;
  final ProfileStore? profile;
  final FolderRepository? folders;
  final SharedFolderService? sharedFolders;

  static Future<AppDependencies> bootstrap() async {
    final media = PlatformMediaGateway();
    final root = await media.managedRoot();
    final database = await ProjectDatabase.open(Directory(root));
    final assets = SqliteAssetRepository(
      database,
      inspector: NativeAssetInspector(media),
    );
    return AppDependencies(
      database: database,
      media: media,
      presentation: PlatformMediaPresentationGateway(),
      projects: SqliteProjectRepository(database),
      assets: assets,
      profile: ProfileStore(File('$root/owner_name.txt')),
      folders: SqliteFolderRepository(database),
      sharedFolders: SharedFolderService(database: database, assets: assets),
    );
  }

  void close() {
    sharedFolders?.close();
    database.close();
  }
}
