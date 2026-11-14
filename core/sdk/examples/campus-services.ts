import type {
  CampusReadRequest,
  CampusReadResult,
} from "../campus-services";
import type { NativeServiceJobScheduleParams } from "../index";

/** Native UI/IPC/FFI request; this is not an additional ctx method. */
export const catalogRequest: CampusReadRequest<"fudan.catalog.lessons"> = {
  id: "catalog-window",
  method: "fudan.catalog.lessons",
  params: {
    account_id: "sample-account",
    // Obtain this opaque ID from fudan.catalog.semesters; do not hard-code a live semester.
    semester_id: "902",
    page: 1,
    page_size: 20,
    filters: { courseNameZhLike: "Synthetic subject" },
  },
};

export const catalogJob: NativeServiceJobScheduleParams = {
  kind: "service",
  method: catalogRequest.method,
  input: { ...catalogRequest.params },
  run_at: "2099-01-01T00:00:00Z",
};

export function canContinueEhallTasks(result: CampusReadResult<"fudan.ehall.tasks.sync">): boolean {
  return !result.complete && result.next_page !== null && result.stop.reason === "budget";
}

export const selfGradeRequest: CampusReadRequest<"canvas.grades.self"> = {
  id: "self-grades",
  method: "canvas.grades.self",
  // No arbitrary student/user ID can be supplied to a self endpoint.
  params: { account_id: "sample-account", course_id: "81001" },
};
