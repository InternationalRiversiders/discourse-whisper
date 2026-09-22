// Kept identical in the six standalone campus plugins; no cross-plugin dependency.
export const FALLBACK_TIME_ZONE = "Asia/Shanghai";

export function browserTimeZone() {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone) {
      new Intl.DateTimeFormat(undefined, { timeZone: zone }).format(0);
      return zone;
    }
  } catch {}
  return FALLBACK_TIME_ZONE;
}

export function asDate(value) {
  if (value === null || value === undefined || value === "") { return null; }
  let input = value;
  // Historical timestamps without an offset used UTC+8. Date-only values are
  // calendar dates, not instants, and must not move to the previous day.
  if (typeof input === "string") {
    input = input.trim();
    if (/^\d{4}-\d{2}-\d{2}$/.test(input)) { input += "T00:00:00+08:00"; }
    else if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$/.test(input)) {
      input = input.replace(" ", "T") + "+08:00";
    }
  }
  const date = new Date(input);
  return Number.isNaN(date.getTime()) ? null : date;
}

function format(value, kind) {
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return kind === "time" ? "—" : value;
  }
  const date = asDate(value);
  if (!date) { return "—"; }
  const options = { timeZone: browserTimeZone() };
  if (kind !== "time") { Object.assign(options, { year: "numeric", month: "2-digit", day: "2-digit" }); }
  if (kind !== "date") { Object.assign(options, { hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" }); }
  try { return new Intl.DateTimeFormat(undefined, options).format(date); }
  catch {
    // Even without a working Intl implementation, never silently use UTC.
    const shifted = new Date(date.getTime() + 8 * 60 * 60 * 1000).toISOString();
    const day = shifted.slice(0, 10), time = shifted.slice(11, 19);
    return kind === "date" ? day : kind === "time" ? time : day + " " + time;
  }
}
export const formatDateTime = (value) => format(value, "datetime");
export const formatDate = (value) => format(value, "date");
export const formatTime = (value) => format(value, "time");
