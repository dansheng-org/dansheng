// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../learning_controller.dart';
import '../models/canvas_models.dart';

/// Enrolled courses section with course summary, nested folder/file hierarchy,
/// modules integration, announcements tab, and real file download + open actions via parent bridge.
class CourseFilesView extends StatefulWidget {
  final LearningController controller;

  const CourseFilesView({super.key, required this.controller});

  @override
  State<CourseFilesView> createState() => _CourseFilesViewState();
}

class _CourseFilesViewState extends State<CourseFilesView> {
  int _tabIndex = 0; // 0 = 资料与模块 (Materials & Modules), 1 = 公告 (Announcements)
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ctrl = widget.controller;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Row(
            children: [
              Icon(Icons.school_rounded, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '已选课程与资料',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              if (ctrl.canvasFromCache)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '离线缓存',
                    style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Canvas Auth / Error banner (Per-source isolation)
          if (ctrl.canvasAuthRequired)
            _buildCanvasAuthBanner(context, colorScheme)
          else if (ctrl.canvasError != null && ctrl.courses.isEmpty)
            _buildCanvasErrorBanner(context, colorScheme)
          else if (ctrl.courses.isEmpty)
            _buildEmptyCourses(context, colorScheme)
          else
            _buildCoursesContent(context, colorScheme),
        ],
      ),
    );
  }

  Widget _buildCanvasAuthBanner(BuildContext context, ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 20, color: colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '学习平台需要登录以获取课程课件',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
          FilledButton.tonal(
            onPressed: widget.controller.loginCanvas,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('登录 Canvas'),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasErrorBanner(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.controller.canvasError ?? '课程资料加载失败',
              style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
            ),
          ),
          TextButton(
            onPressed: widget.controller.loadCanvas,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyCourses(BuildContext context, ColorScheme colorScheme) {
    if (widget.controller.canvasLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          Icon(Icons.menu_book_rounded, size: 28, color: colorScheme.outline),
          const SizedBox(height: 6),
          Text(
            '暂无已选课程',
            style: TextStyle(fontSize: 13, color: colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _buildCoursesContent(BuildContext context, ColorScheme colorScheme) {
    final ctrl = widget.controller;
    final selectedId = ctrl.selectedCourseId ?? ctrl.courses.first.id;
    final selectedCourse = ctrl.courses.firstWhere(
      (c) => c.id == selectedId,
      orElse: () => ctrl.courses.first,
    );

    final folders = ctrl.folders[selectedId] ?? [];
    final materials = ctrl.materials[selectedId] ?? [];
    final modules = ctrl.modules[selectedId] ?? [];
    final assignments = ctrl.assignments[selectedId] ?? [];
    final announcements = ctrl.announcements[selectedId] ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Horizontal course chips selector
        if (ctrl.canvasError != null)
          _buildCanvasErrorBanner(context, colorScheme),
        if (ctrl.detailsError(selectedId) != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ctrl.detailsError(selectedId)!,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => ctrl.loadCourseDetails(selectedId),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: ctrl.courses.map((course) {
              final isSel = course.id == selectedId;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(
                    course.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: isSel,
                  onSelected: (_) => ctrl.selectCourse(course.id),
                  visualDensity: VisualDensity.compact,
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 10),

        // Course details & summary card
        Card(
          elevation: 0,
          color: colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Course summary top row
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selectedCourse.name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (selectedCourse.courseCode != null) ...[
                                Text(
                                  selectedCourse.courseCode!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (selectedCourse.termName != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    selectedCourse.termName!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Sub-tab switch: 资料与模块 vs 公告
                    SegmentedButton<int>(
                      segments: [
                        const ButtonSegment(
                          value: 0,
                          label: Text('资料', style: TextStyle(fontSize: 12)),
                        ),
                        ButtonSegment(
                          value: 1,
                          label: Text(
                            announcements.isNotEmpty
                                ? '公告(${announcements.length})'
                                : '公告',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                      selected: {_tabIndex},
                      onSelectionChanged: (set) {
                        if (set.isNotEmpty) {
                          setState(() => _tabIndex = set.first);
                        }
                      },
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: WidgetStateProperty.all(
                          const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Course stats summary badges
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildSummaryBadge(
                        colorScheme,
                        icon: Icons.folder_outlined,
                        label: '${folders.length} 文件夹',
                      ),
                      const SizedBox(width: 6),
                      _buildSummaryBadge(
                        colorScheme,
                        icon: Icons.insert_drive_file_outlined,
                        label: '${materials.length} 课件文件',
                      ),
                      if (modules.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _buildSummaryBadge(
                          colorScheme,
                          icon: Icons.view_module_outlined,
                          label: '${modules.length} 学习模块',
                        ),
                      ],
                      if (assignments.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _buildSummaryBadge(
                          colorScheme,
                          icon: Icons.assignment_outlined,
                          label: '${assignments.length} 项作业',
                        ),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 22),

                // Tab Content
                if (_tabIndex == 0)
                  _buildMaterialsAndModulesTab(
                    context,
                    colorScheme,
                    courseId: selectedId,
                    folders: folders,
                    materials: materials,
                    modules: modules,
                  )
                else
                  _buildAnnouncementsTab(context, colorScheme, selectedId),
              ],
            ),
          ),
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
