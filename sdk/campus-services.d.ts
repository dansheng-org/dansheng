/** Official native service RPC declarations for trusted embedding clients.
 * These are not PluginContext methods. Host/FFI must enable `services`, register
 * CampusService and authenticate the caller; method visibility grants no access.
 */
export type CampusDecimalId = string;
export interface ObservedSource {
  account_id: string;
  source_id: string;
  observed_at: string;
}
export interface ObservedRecord<T> extends ObservedSource {
  external_id: string;
  updated_at: string | null;
  payload: T;
}
export type SourceCoverage =
  | { state: "complete" }
  | { state: "page"; next: number | null; total: number | null }
  | { state: "window"; position: string }
  | { state: "unsupported_remainder"; reported_total: number; returned: number };
export interface ObservedBatch<T> {
  source: ObservedSource;
  source_revision: string;
  records: ObservedRecord<T>[];
  coverage: SourceCoverage;
}
export interface AcademicSemesterCatalog {
  semesters: Array<{ id: CampusDecimalId; name: string }>;
  default_semester_id: CampusDecimalId;
}
export type AcademicCatalogFilter =
  | "courseCodeLike" | "courseNameZhLike" | "codeLike" | "nameZhLike"
  | "teacherNameLike" | "roomNameLike" | "teachingSyllabus"
  | "creditsGte" | "creditsLte" | "scheduleWeekGte" | "scheduleWeekLte"
  | "limitCountGte" | "limitCountLte" | "stdCountGte" | "stdCountLte";
export interface AcademicCatalogCourse {
  course_id: CampusDecimalId;
  code: string;
  name: string;
  credits: string | null;
  subject_class: string | null;
  level: string | null;
}
export interface AcademicCatalogLesson {
  semester_id: CampusDecimalId;
  lesson_id: CampusDecimalId;
  lesson_code: string;
  name: string;
  course: AcademicCatalogCourse;
  department: string | null;
  teachers: string[];
  schedule_text: string | null;
  teaching_language: string | null;
  enrollment_limit: string | null;
  enrolled: string | null;
}
export interface AcademicSyllabus {
  lesson_id: CampusDecimalId;
  sections: Array<{ title: string; text: string }>;
  /** Supported paragraph text only; dynamic tables may not be covered. */
  text_coverage: SourceCoverage;
}
export interface CachedCourseProjection {
  account_id: string;
  source_id: string;
  external_id: string;
  payload: AcademicCatalogCourse;
  cached_at: string;
  cache_state: "cached_catalog_projection";
}
export interface PublicProgramSummary {
  program_id: CampusDecimalId;
  biz_type_id: string;
  public_scope: string;
  title: string;
  cohort: string | null;
  major_id: string | null;
  major_name: string | null;
  department_name: string | null;
  department_ids: string[];
  publication_state: string | null;
}
export interface PublicProgramEntity { id: string | null; name: string | null; code: string | null }
export interface PublicProgramSection {
  id: string;
  position: number | null;
  level: number | null;
  title: string | null;
  title_en: string | null;
  text: string | null;
  text_en: string | null;
  mode: "normal" | "course_module_setting" | "study_require" | "unknown";
}
export interface PublicProgramModule {
  id: string;
  name: string | null;
  name_en: string | null;
  parent_id: string | null;
  child_ids: string[];
  required_credits: string | null;
  required_courses: number | null;
  required_submodules: number | null;
  credits_upper_limit: string | null;
  courses_upper_limit: number | null;
  courses: Array<{ plan_course_id: string; course_id: CampusDecimalId; code: string; name: string; credits: string | null; compulsory: boolean | null; terms_text: string | null }>;
}
/** Public rules projection, not any student's earned credits or degree status. */
export interface PublicProgramDetail {
  program_id: CampusDecimalId;
  biz_type_id: string;
  public_scope: string;
  title: string;
  title_en: string | null;
  cohort: string | null;
  source_program_type: string | null;
  education: PublicProgramEntity | null;
  major: PublicProgramEntity | null;
  department: PublicProgramEntity | null;
  credits_required: string | null;
  duration_years: string | null;
  terms_count: number | null;
  effective_on: string | null;
  invalid_on: string | null;
  publication_state: string | null;
  sections: PublicProgramSection[];
  course_modules: PublicProgramModule[];
  coverage: {
    sections: SourceCoverage;
    course_tree: SourceCoverage;
    ignored_special_module_count: number;
    unsupported_parent_reference_count: number;
    ignored_dynamic_course_count: number;
    ambiguous_module_count: number;
    unknown_section_mode_count: number;
    document_present: boolean;
    study_require_present: boolean;
    unprojected_regions: string[];
  };
}
export type EhallTaskKind = "todo" | "done" | "application";
export interface EhallCatalogEntry {
  id: string;
  title: string;
  description: string | null;
  description_state: "present" | "missing" | "omitted_unsafe" | "omitted_too_large";
  category: string | null;
  pc_url: string | null;
  mobile_url: string | null;
  access_hint: "advertised" | "restricted" | "unknown";
  internal_ref: string;
}
export type EhallApplicationStatus =
  | { state: "in_progress" | "terminated" | "completed" | "withdrawn" }
  | { state: "unknown"; code: string | null };
export interface EhallTaskSummary {
  id: string;
  kind: EhallTaskKind;
  title: string;
  current_step: string | null;
  created_at: string | null;
  finished_at: string | null;
  application_status: EhallApplicationStatus | null;
  /** Summary reference, never a signed form/process URL or a URL opener. */
  internal_ref: string;
}
export type EhallReadFailure =
  | { kind: "authentication" | "permission" | "timeout" | "unsafe_response" | "limit" | "source_changed" | "transport" }
  | { kind: "http"; status: number };
export interface EhallTaskCollection {
  batch: ObservedBatch<EhallTaskSummary>;
  complete: boolean;
  pages_read: number;
  bytes_read: number;
  next_page: number | null;
  stop:
    | { reason: "end_of_reported_list" | "unverified_end" | "budget" | "duplicate_id" | "inconsistent_pagination" }
    | { reason: "interrupted"; failure: EhallReadFailure };
}
export interface LibraryVolumeMatch {
  catalogue_id: CampusDecimalId;
  lookup_kind: "barcode" | "call_number";
  official_url: string;
}
export interface LibraryBibliography {
  catalogue_id: CampusDecimalId;
  title: string;
  authors: string[];
  publisher: string | null;
  publication_place: string | null;
  publication_year: number | null;
  isbns: string[];
  resource_kind: string | null;
  official_url: string;
}
export interface LibrarySourceDate {
  raw: string;
  source_field: string;
  precision: "date_only" | "date_time_without_zone" | "date_time_with_explicit_zone" | "numeric_unknown_unit" | "unclassified";
  meaning: "checkout" | "due_as_displayed_by_official_current_loan_ui" | "expected_return_as_displayed_by_holdings_ui" | "returned_as_displayed_by_official_history_ui";
  timezone: string | null;
}
export interface LibraryHolding {
  id: string;
  catalogue_id: CampusDecimalId;
  call_number: string | null;
  permanent_library: string | null;
  permanent_location: string | null;
  temporary_library: string | null;
  temporary_location: string | null;
  item_status: string;
  item_status_name: string | null;
  known_available: boolean;
  expected_return: LibrarySourceDate | null;
  volume_info: string | null;
}
export interface LibraryLoan {
  kind: "current" | "history";
  title: string | null;
  authors: string[];
  catalogue_id: CampusDecimalId | null;
  item_ref: string | null;
  checkout: LibrarySourceDate | null;
  due: LibrarySourceDate | null;
  returned: LibrarySourceDate | null;
  renewal_count: number | null;
  location: string | null;
  call_number: string | null;
  /** No raw reader barcode, contact details or token is returned. */
  id_basis: "source_id" | "account_item_fingerprint" | "content_fingerprint";
}
export interface LibraryLoanPage {
  batch: ObservedBatch<LibraryLoan>;
  identity: "matched_trusted_fingerprint";
  /** Current private schema is from public JS, not a real account acceptance. */
  protocol_live_validated: boolean;
}
export interface CanvasReadPermission { read: boolean | null }
export interface CanvasLearningAttachment {
  id: CampusDecimalId | null;
  display_name: string | null;
  filename: string | null;
  "content-type": string | null;
  size: number | null;
}
export interface CanvasClassicQuiz {
  id: CampusDecimalId;
  title: string;
  course_id: CampusDecimalId | null;
  description: string | null;
  quiz_type: string | null;
  assignment_id: CampusDecimalId | null;
  assignment_group_id: CampusDecimalId | null;
  time_limit: number | null;
  allowed_attempts: number | null;
  question_count: number | null;
  points_possible: number | null;
  due_at: string | null;
  unlock_at: string | null;
  lock_at: string | null;
  published: boolean | null;
  locked_for_user: boolean | null;
  html_url: string | null;
  updated_at: string | null;
  permissions: CanvasReadPermission | null;
}
export interface CanvasDiscussionTopic {
  id: CampusDecimalId;
  title: string;
  course_id: CampusDecimalId | null;
  context_code: string | null;
  message: string | null;
  html_url: string | null;
  posted_at: string | null;
  last_reply_at: string | null;
  updated_at: string | null;
  discussion_type: string | null;
  discussion_subentry_count: number | null;
  read_state: string | null;
  require_initial_post: boolean | null;
  user_can_see_posts: boolean | null;
  locked: boolean | null;
  locked_for_user: boolean | null;
  is_announcement: boolean | null;
  permissions: CanvasReadPermission | null;
  attachments: CanvasLearningAttachment[];
}
export interface CanvasDiscussionEntry {
  id: CampusDecimalId;
  user_id: CampusDecimalId | null;
  parent_id: CampusDecimalId | null;
  message: string | null;
  created_at: string | null;
  updated_at: string | null;
  deleted: boolean | null;
  replies: CanvasDiscussionEntry[];
}
export interface CanvasDiscussionView {
  view: CanvasDiscussionEntry[];
  participants: Array<{ id: CampusDecimalId; display_name: string | null }>;
  unread_entries: CampusDecimalId[];
  forced_entries: CampusDecimalId[];
}
export interface CanvasAssignmentGroup {
  id: CampusDecimalId;
  name: string;
  course_id: CampusDecimalId | null;
  position: number | null;
  group_weight: number | null;
  rules: { drop_lowest: number | null; drop_highest: number | null; never_drop: CampusDecimalId[] } | null;
}
export interface CanvasSelfSubmission {
  assignment_id: CampusDecimalId;
  user_id: CampusDecimalId;
  course_id: CampusDecimalId | null;
  attempt: number | null;
  body: string | null;
  grade: string | null;
  score: number | null;
  grade_matches_current_submission: boolean | null;
  submission_type: string | null;
  workflow_state: string | null;
  submitted_at: string | null;
  graded_at: string | null;
  posted_at: string | null;
  updated_at: string | null;
  late: boolean | null;
  missing: boolean | null;
  excused: boolean | null;
  assignment_visible: boolean | null;
  html_url: string | null;
  attachments: CanvasLearningAttachment[];
  submission_comments: Array<{ id: CampusDecimalId; author_id: CampusDecimalId | null; author_name: string | null; comment: string | null; created_at: string | null }>;
}
export interface CanvasPublishedGrades {
  current_grade: string | null;
  final_grade: string | null;
  current_score: number | null;
  final_score: number | null;
  current_points: number | null;
  html_url: string | null;
}
export interface CanvasSelfEnrollment {
  id: CampusDecimalId;
  course_id: CampusDecimalId;
  user_id: CampusDecimalId;
  course_section_id: CampusDecimalId | null;
  type: string;
  enrollment_state: string | null;
  role: string | null;
  created_at: string | null;
  updated_at: string | null;
  grades: CanvasPublishedGrades | null;
}
export interface CanvasSelfGradeSummary {
  enrollment_id: CampusDecimalId;
  course_id: CampusDecimalId;
  user_id: CampusDecimalId;
  enrollment_state: string | null;
  grades: CanvasPublishedGrades | null;
}
interface AccountParams { account_id: string }
interface PageParams extends AccountParams { page?: number; page_size?: number }
interface CourseParams extends AccountParams { course_id: CampusDecimalId }
interface ServiceContract<P, R> { params: P; result: R }
export interface CampusReadServiceMap {
  "fudan.catalog.semesters": ServiceContract<AccountParams, ObservedRecord<AcademicSemesterCatalog>>;
  "fudan.catalog.lessons": ServiceContract<PageParams & { semester_id: CampusDecimalId; filters?: Partial<Record<AcademicCatalogFilter, string>> }, ObservedBatch<AcademicCatalogLesson>>;
  "fudan.catalog.course": ServiceContract<AccountParams & { semester_id: CampusDecimalId; course_id: CampusDecimalId }, CachedCourseProjection>;
  "fudan.catalog.syllabus": ServiceContract<AccountParams & { lesson_id: CampusDecimalId }, ObservedRecord<AcademicSyllabus>>;
  "fudan.programs.list": ServiceContract<PageParams, ObservedBatch<PublicProgramSummary>>;
  "fudan.programs.detail": ServiceContract<AccountParams & { program_id: CampusDecimalId }, ObservedRecord<PublicProgramDetail>>;
  "fudan.ehall.catalog": ServiceContract<AccountParams & { limit?: number }, ObservedBatch<EhallCatalogEntry>>;
  "fudan.ehall.tasks": ServiceContract<PageParams & { kind?: EhallTaskKind }, ObservedBatch<EhallTaskSummary>>;
  "fudan.ehall.tasks.sync": ServiceContract<AccountParams & { kind?: EhallTaskKind; page_size?: number; max_pages?: number; max_items?: number; max_bytes?: number }, EhallTaskCollection>;
  "fudan.library.lookup": ServiceContract<AccountParams & { kind: "barcode" | "call_number"; value: string; limit?: number }, ObservedBatch<LibraryVolumeMatch>>;
  "fudan.library.bibliography": ServiceContract<AccountParams & { catalogue_id: CampusDecimalId }, ObservedRecord<LibraryBibliography>>;
  "fudan.library.holdings": ServiceContract<PageParams & { catalogue_id: CampusDecimalId }, ObservedBatch<LibraryHolding>>;
  "fudan.library.loans.current": ServiceContract<PageParams, LibraryLoanPage>;
  "fudan.library.loans.history": ServiceContract<PageParams, LibraryLoanPage>;
  "canvas.quizzes.sync": ServiceContract<CourseParams, ObservedRecord<CanvasClassicQuiz>[]>;
  "canvas.quiz.read": ServiceContract<CourseParams & { quiz_id: CampusDecimalId }, ObservedRecord<CanvasClassicQuiz>[]>;
  "canvas.discussions.sync": ServiceContract<CourseParams, ObservedRecord<CanvasDiscussionTopic>[]>;
  "canvas.discussion.read": ServiceContract<CourseParams & { topic_id: CampusDecimalId }, ObservedRecord<CanvasDiscussionTopic>[]>;
  "canvas.discussion.view": ServiceContract<CourseParams & { topic_id: CampusDecimalId }, ObservedRecord<CanvasDiscussionView>[]>;
  "canvas.assignment_groups.sync": ServiceContract<CourseParams, ObservedRecord<CanvasAssignmentGroup>[]>;
  "canvas.submission.self": ServiceContract<CourseParams & { assignment_id: CampusDecimalId }, ObservedRecord<CanvasSelfSubmission>[]>;
  "canvas.enrollments.self": ServiceContract<CourseParams, ObservedRecord<CanvasSelfEnrollment>[]>;
  "canvas.grades.self": ServiceContract<CourseParams, ObservedRecord<CanvasSelfGradeSummary>[]>;
}
export type CampusReadMethod = keyof CampusReadServiceMap;
export type CampusReadParams<M extends CampusReadMethod> = CampusReadServiceMap[M]["params"];
export type CampusReadResult<M extends CampusReadMethod> = CampusReadServiceMap[M]["result"];
export type CampusReadRequest<M extends CampusReadMethod> = { id: string; method: M; params: CampusReadParams<M> };
/** Owner configuration is a separate RPC surface, excluded from MCP and jobs. */
export interface OwnerCampusServiceMap {
  "canvas.configure": ServiceContract<AccountParams & { origin?: string; access?: "host_token" | "host_session" | "browser_session"; download_origins?: string[] }, { origin: string; access: "host_token" | "host_session" | "browser_session"; download_origins: string[] }>;
  "fudan.library.reader.observe": ServiceContract<AccountParams, { reader_ref: string; state: "observed_unbound" }>;
  /** Fingerprint must be independently verified by the trusted host; observation alone is insufficient. */
  "fudan.library.reader.bind": ServiceContract<AccountParams & { reader_ref: string }, { account_id: string; bound: true; verification: "owner_provided_fingerprint" }>;
  "fudan.library.reader.clear": ServiceContract<AccountParams, { account_id: string; bound: false }>;
}
