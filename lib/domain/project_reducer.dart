import 'project.dart';

sealed class ProjectEditCommand {
  const ProjectEditCommand();
}

final class RenameProject extends ProjectEditCommand {
  const RenameProject(this.title);
  final String title;
}

final class AddClip extends ProjectEditCommand {
  const AddClip(this.assetId);
  final String assetId;
}

final class RemoveClip extends ProjectEditCommand {
  const RemoveClip(this.assetId);
  final String assetId;
}

final class ReplaceClip extends ProjectEditCommand {
  const ReplaceClip(this.oldAssetId, this.newAssetId);
  final String oldAssetId;
  final String newAssetId;
}

final class ReorderClips extends ProjectEditCommand {
  const ReorderClips(this.assetIds);
  final List<String> assetIds;
}

final class SetArrangementJson extends ProjectEditCommand {
  const SetArrangementJson(this.value);
  final Map<String, Object?> value;
}

final class SetVideoRecipeJson extends ProjectEditCommand {
  const SetVideoRecipeJson(this.value);
  final Map<String, Object?> value;
}

abstract final class ProjectReducer {
  static Project reduce(
    Project project,
    ProjectEditCommand command, {
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return switch (command) {
      RenameProject(:final title) => project.copyWith(
        title: title,
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      AddClip(:final assetId) => project.copyWith(
        clipIds: <String>[...project.clipIds, assetId],
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      RemoveClip(:final assetId) => project.copyWith(
        clipIds: project.clipIds.where((id) => id != assetId).toList(),
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      ReplaceClip(:final oldAssetId, :final newAssetId) => project.copyWith(
        clipIds: project.clipIds
            .map((id) => id == oldAssetId ? newAssetId : id)
            .toList(),
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      ReorderClips(:final assetIds) => _reorder(project, assetIds, timestamp),
      SetArrangementJson(:final value) => project.copyWith(
        arrangement: value,
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      SetVideoRecipeJson(:final value) => project.copyWith(
        videoRecipe: value,
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
    };
  }

  static Project _reorder(
    Project project,
    List<String> assetIds,
    DateTime timestamp,
  ) {
    if (assetIds.length != project.clipIds.length ||
        !assetIds.toSet().containsAll(project.clipIds)) {
      throw const ProjectValidationException(
        'Reordering must retain exactly the current clips.',
      );
    }
    return project.copyWith(
      clipIds: assetIds,
      revision: project.revision + 1,
      updatedAt: timestamp,
    );
  }
}
