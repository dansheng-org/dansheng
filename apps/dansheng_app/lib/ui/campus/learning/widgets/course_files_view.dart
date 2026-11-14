// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../learning_controller.dart';
import '../models/canvas_models.dart';
import 'day_schedule_view.dart';
import 'learning_common.dart';

/// eLearning content of one course: files and modules, assignments and
/// announcements, with real file download + open actions via parent bridge.
class CourseFilesView extends StatefulWidget {
  final LearningController controller;
  final String courseId;

  const CourseFilesView({
    super.key,
    required this.controller,
    required this.courseId,
  });

  @override
  State<CourseFilesView> createState() => _CourseFilesViewState();
}

class _CourseFilesViewState extends State<CourseFilesView> {
  int _tabIndex = 0; // 0 = 资料, 1 = 作业, 2 = 公告
  final Set<String> _expandedFolderIds = {};

  void _toggleFolder(String folderId) {
    setState(() {
      if (_expandedFolderIds.contains(folderId)) {
        _expandedFolderIds.remove(folderId);
      } else {
        _expandedFolderIds.add(folderId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final ctrl = widget.controller;
    final id = widget.courseId;

    final folders = ctrl.folders[id] ?? const <CanvasFolder>[];
    final materials = ctrl.materials[id] ?? const <CanvasMaterial>[];
    final modules = ctrl.modules[id] ?? const <CanvasModule>[];
    final assignments = ctrl.assignments[id] ?? const <CanvasAssignment>[];
    final announcements =
        ctrl.announcements[id] ?? const <CanvasAnnouncement>[];
    final loading = ctrl.isCourseLoading(id);
    final detailError = ctrl.detailsError(id);
    const label = TextStyle(fontSize: 12);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detailError != null)
          InfoBanner(
            message: detailError,
            actionLabel: '重试',
            onAction: () => ctrl.loadCourseDetails(id),
          ),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: 0, label: Text('资料', style: label)),
              ButtonSegment(
                value: 1,
                label: Text(
                  assignments.isNotEmpty ? '作业(${assignments.length})' : '作业',
                  style: label,
                ),
              ),
              ButtonSegment(
                value: 2,
                label: Text(
                  announcements.isNotEmpty
                      ? '公告(${announcements.length})'
                      : '公告',
                  style: label,
                ),
              ),
            ],
            selected: {_tabIndex},
            onSelectionChanged: (set) {
              if (set.isNotEmpty) {
                setState(() => _tabIndex = set.first);
              }
            },
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
        ),
        const SizedBox(height: 12),
        if (_tabIndex == 0) ...[
          if (loading &&
              folders.isEmpty &&
              materials.isEmpty &&
              modules.isEmpty)
            const SectionSpinner()
          else ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _buildSummaryBadge(
                  colorScheme,
                  icon: Icons.folder_outlined,
                  label: '${folders.length} 文件夹',
                ),
                _buildSummaryBadge(
                  colorScheme,
                  icon: Icons.insert_drive_file_outlined,
                  label: '${materials.length} 课件文件',
                ),
                if (modules.isNotEmpty)
                  _buildSummaryBadge(
                    colorScheme,
                    icon: Icons.view_module_outlined,
                    label: '${modules.length} 学习模块',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _buildMaterialsAndModulesTab(
              context,
              colorScheme,
              courseId: id,
              folders: folders,
              materials: materials,
              modules: modules,
            ),
          ],
        ] else if (_tabIndex == 1)
          _buildAssignmentsTab(context, colorScheme, assignments, loading)
        else
          _buildAnnouncementsTab(context, colorScheme, id),
      ],
    );
  }

  Widget _buildAssignmentsTab(
    BuildContext context,
    ColorScheme colorScheme,
    List<CanvasAssignment> assignments,
    bool loading,
  ) {
    if (assignments.isEmpty) {
      return loading
          ? const SectionSpinner()
          : const EmptyHint(
              icon: Icons.assignment_turned_in_outlined,
              text: '此课程暂无作业',
            );
    }
    // Upcoming deadlines first (soonest on top), then undated, then past.
    final now = widget.controller.currentTime();
    int rank(CanvasAssignment a) =>
        a.dueAt == null ? 1 : (a.dueAt!.isBefore(now) ? 2 : 0);
    final sorted = List<CanvasAssignment>.of(assignments)
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0 || a.dueAt == null || b.dueAt == null) return byRank;
        return rank(a) == 0
            ? a.dueAt!.compareTo(b.dueAt!)
            : b.dueAt!.compareTo(a.dueAt!);
      });
    return Column(
      children: [
        for (final assignment in sorted)
          AssignmentCard(
            assignment: assignment,
            colorScheme: colorScheme,
            inCourse: true,
            onTap: () => showAssignmentDetails(context, assignment),
          ),
      ],
    );
  }

  Widget _buildSummaryBadge(
    ColorScheme colorScheme, {
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildMaterialsAndModulesTab(
    BuildContext context,
    ColorScheme colorScheme, {
    required String courseId,
    required List<CanvasFolder> folders,
    required List<CanvasMaterial> materials,
    required List<CanvasModule> modules,
  }) {
    if (folders.isEmpty && materials.isEmpty && modules.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 28,
                color: colorScheme.outline,
              ),
              const SizedBox(height: 6),
              Text(
                '此课程暂无文件或资料',
                style: TextStyle(fontSize: 13, color: colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    // Build hierarchy preserving exact IDs (without flattening)
    final folderMap = {for (var f in folders) f.id: f};
    final rootFolders = folders.where((f) {
      return f.parentFolderId == null ||
          !folderMap.containsKey(f.parentFolderId);
    }).toList();

    final rootMaterials = materials.where((m) {
      return m.folderId == null || !folderMap.containsKey(m.folderId);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Modules section if modules available
        if (modules.isNotEmpty) ...[
          Row(
            children: [
              Icon(
                Icons.view_module_rounded,
                size: 16,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '教学模块',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...modules.map((mod) => _buildModuleCard(context, colorScheme, mod)),
          const Divider(height: 20),
        ],

        // Files & Folders section
        Row(
          children: [
            Icon(
              Icons.folder_copy_rounded,
              size: 16,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              '课件目录',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Root files
        ...rootMaterials.map(
          (m) => _buildFileRow(
            context,
            colorScheme,
            courseId: courseId,
            material: m,
            indent: 0,
          ),
        ),

        // Root folders and their recursive subfolders
        ...rootFolders.map(
          (f) => _buildFolderTree(
            context,
            colorScheme,
            courseId: courseId,
            folder: f,
            allFolders: folders,
            allMaterials: materials,
            level: 0,
          ),
        ),
      ],
    );
  }

  Widget _buildModuleCard(
    BuildContext context,
    ColorScheme colorScheme,
    CanvasModule module,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.book_outlined, size: 18, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              module.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          if (module.itemsCount > 0)
            Text(
              '${module.itemsCount} 项内容',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFolderTree(
    BuildContext context,
    ColorScheme colorScheme, {
    required String courseId,
    required CanvasFolder folder,
    required List<CanvasFolder> allFolders,
    required List<CanvasMaterial> allMaterials,
    required int level,
  }) {
    final isExpanded = _expandedFolderIds.contains(folder.id);
    final childFolders = allFolders
        .where((f) => f.parentFolderId == folder.id)
        .toList();
    final childMaterials = allMaterials
        .where((m) => m.folderId == folder.id)
        .toList();
    final totalItems = childFolders.length + childMaterials.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => _toggleFolder(folder.id),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.only(
              left: level * 16.0 + 4,
              top: 6,
              bottom: 6,
              right: 8,
            ),
            child: Row(
              children: [
                Icon(
                  isExpanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    folder.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                if (totalItems > 0)
                  Text(
                    '$totalItems 项',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded) ...[
          // Sub-folders
          ...childFolders.map(
            (sub) => _buildFolderTree(
              context,
              colorScheme,
              courseId: courseId,
              folder: sub,
              allFolders: allFolders,
              allMaterials: allMaterials,
              level: level + 1,
            ),
          ),
          // Sub-files
          ...childMaterials.map(
            (m) => _buildFileRow(
              context,
              colorScheme,
              courseId: courseId,
              material: m,
              indent: level + 1,
            ),
          ),
          if (totalItems == 0)
            Padding(
              padding: EdgeInsets.only(
                left: (level + 1) * 16.0 + 12,
                top: 4,
                bottom: 4,
              ),
              child: Text(
                '文件夹为空',
                style: TextStyle(fontSize: 12, color: colorScheme.outline),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildFileRow(
    BuildContext context,
    ColorScheme colorScheme, {
    required String courseId,
    required CanvasMaterial material,
    required int indent,
  }) {
    final isDownloading = widget.controller.downloadingFileIds.contains(
      material.id,
    );
    final isDownloaded = widget.controller.downloadedFileIds.contains(
      material.id,
    );

    return Padding(
      padding: EdgeInsets.only(
        left: indent * 16.0 + 8,
        top: 4,
        bottom: 4,
        right: 4,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            _getFileIcon(material.filename, colorScheme),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    material.displayName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (material.sizeFormatted.isNotEmpty)
                    Text(
                      material.sizeFormatted,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (isDownloading)
              const SizedBox(
                width: 28,
                height: 28,
                child: Padding(
                  padding: EdgeInsets.all(4.0),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                icon: Icon(
                  isDownloaded
                      ? Icons.open_in_new_rounded
                      : Icons.download_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                tooltip: isDownloaded ? '打开文件' : '下载并打开',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  widget.controller.downloadAndOpenFile(
                    courseId: material.courseId ?? courseId,
                    fileId: material.id,
                    fileName: material.displayName,
                    showFeedback: (msg, {isError = false}) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          backgroundColor: isError
                              ? colorScheme.error
                              : colorScheme.inverseSurface,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _getFileIcon(String filename, ColorScheme colorScheme) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return const Icon(
        Icons.picture_as_pdf_rounded,
        size: 22,
        color: Colors.redAccent,
      );
    }
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) {
      return const Icon(
        Icons.description_rounded,
        size: 22,
        color: Colors.blueAccent,
      );
    }
    if (lower.endsWith('.ppt') || lower.endsWith('.pptx')) {
      return const Icon(
        Icons.slideshow_rounded,
        size: 22,
        color: Colors.orangeAccent,
      );
    }
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx')) {
      return const Icon(
        Icons.table_chart_rounded,
        size: 22,
        color: Colors.green,
      );
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.rar') ||
        lower.endsWith('.7z')) {
      return const Icon(
        Icons.folder_zip_rounded,
        size: 22,
        color: Colors.amber,
      );
    }
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg')) {
      return const Icon(Icons.image_rounded, size: 22, color: Colors.teal);
    }
    return Icon(
      Icons.insert_drive_file_rounded,
      size: 22,
      color: colorScheme.onSurfaceVariant,
    );
  }

  Widget _buildAnnouncementsTab(
    BuildContext context,
    ColorScheme colorScheme,
    String courseId,
  ) {
    final announcements = widget.controller.announcements[courseId] ?? [];

    if (announcements.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.campaign_outlined,
                size: 28,
                color: colorScheme.outline,
              ),
              const SizedBox(height: 6),
              Text(
                '暂无课程公告',
                style: TextStyle(fontSize: 13, color: colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: announcements.map((ann) {
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.campaign_rounded,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ann.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (ann.postedAtFormatted.isNotEmpty)
                    Text(
                      ann.postedAtFormatted,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (ann.message != null && ann.message!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _cleanMessage(ann.message!),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }

  String _cleanMessage(String raw) {
    return raw.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }
}
